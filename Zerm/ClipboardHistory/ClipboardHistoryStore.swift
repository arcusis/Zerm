import AppKit
import CryptoKit
import Foundation

typealias ClipboardHistoryPasteOperation = @Sendable (ClipboardItem, Bool) async throws -> Void

enum ClipboardHistoryStoreCaptureError: Error {
    case itemTooLarge
}

/// Local encrypted clipboard history. Every public operation is asynchronous and serialized by the actor.
actor ClipboardHistoryStore {
    private enum SortKey: String, Codable, Hashable, CaseIterable {
        case lastCopy
        case firstCopy
        case copyCount
        case size
    }

    private struct Metadata: Codable {
        let id: UUID
        var contentHash: String
        var kind: ClipboardItemKind
        var preview: String
        var createdAt: Date
        var lastCopiedAt: Date? = nil
        var lastUsedAt: Date
        var useCount: Int
        var isPinned: Bool
        var isFavorite: Bool
        var collectionID: UUID?
        var title: String?
        var tagIDs: [UUID]? = nil
        var favoriteOrder: Int? = nil
        var payloadSize: Int? = nil
        var recognizedText: String? = nil
        var barcodePayloads: [String]? = nil
        var sourceApp: ClipboardSourceApp
    }

    private struct Payload: Codable {
        let representations: [ClipboardRepresentation]
        var thumbnailData: Data? = nil
        var recognizedText: String?
        var barcodePayloads: [String]?
    }

    private let directoryURL: URL
    private let indexURL: URL
    private let searchIndexURL: URL
    private let sortIndexURL: URL
    private let tagsURL: URL
    private let encryption: ClipboardHistoryEncryption
    private let defaults: UserDefaults
    private var metadata: [Metadata]
    private var metadataIndexByID: [UUID: Int] = [:]
    private var sortOrderIDs: [SortKey: [UUID]] = [:]
    private var payloads: [UUID: [ClipboardRepresentation]]
    private var dirtyPayloadIDs: Set<UUID>
    private var pendingBlobDeletes: Set<UUID> = []
    private var tagsDirty = true
    private var hasLoaded = false
    private var tags: [ClipboardTag] = []
    private var payloadOCR: [UUID: String] = [:]
    private var payloadBarcodes: [UUID: [String]] = [:]
    private var thumbnails: [UUID: Data] = [:]
    private var searchIndex = ClipboardHistorySearchIndex()
    private var indexWriteTask: Task<Void, Never>?
    private var pasteSequenceLastID: UUID?
    private var indexingImageIDs: Set<UUID> = []
    nonisolated let feedStoreID = UUID()

    /// Tests pass a temporary directory and random key. Live installs use a unique Keychain key.
    init(
        directoryURL: URL = AppStoragePaths.root.appendingPathComponent("ClipboardHistory", isDirectory: true),
        keyData: Data? = nil,
        defaults: UserDefaults = .standard
    ) throws {
        self.directoryURL = directoryURL
        self.defaults = defaults
        indexURL = directoryURL.appendingPathComponent("index.enc")
        searchIndexURL = directoryURL.appendingPathComponent("search-index.enc")
        sortIndexURL = directoryURL.appendingPathComponent("sort-index.enc")
        tagsURL = directoryURL.appendingPathComponent("tags.enc")
        let resolvedKey: Data
        if let keyData {
            resolvedKey = keyData
        } else {
            let keyName = "clipboardHistoryEncryptionKey"
            if let saved = KeychainService.shared.getData(forKey: keyName, syncable: false) {
                resolvedKey = saved
            } else {
                let generated = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                guard KeychainService.shared.save(data: generated, forKey: keyName, syncable: false) else {
                    throw ClipboardHistoryError.keychainUnavailable
                }
                resolvedKey = generated
            }
        }
        encryption = try ClipboardHistoryEncryption(keyData: resolvedKey)
        metadata = []
        payloads = [:]
        dirtyPayloadIDs = []
    }

    /// Inserts a new clipboard payload or moves a matching content hash to the top.
    func capture(_ item: ClipboardItem, now: Date = Date()) throws -> ClipboardItem {
        try ensureLoaded()
        guard item.representations.reduce(0, { $0 + $1.data.count }) <= ClipboardHistorySettings.maximumItemSize(in: defaults) else {
            throw ClipboardHistoryStoreCaptureError.itemTooLarge
        }
        guard ClipboardHistoryEngineSettings.shouldCapture(item.kind, defaults: defaults) else { throw ClipboardHistoryCaptureError.retentionDisabled }
        if let maximumSize = ClipboardHistoryEngineSettings.maximumSize(for: item.kind, defaults: defaults),
           item.representations.reduce(0, { $0 + $1.data.count }) > maximumSize {
            throw ClipboardHistoryStoreCaptureError.itemTooLarge
        }
        if let index = metadata.firstIndex(where: { $0.contentHash == item.contentHash }) {
            metadata[index].lastUsedAt = now
            metadata[index].lastCopiedAt = now
            metadata[index].useCount += 1
            metadata[index].sourceApp = item.sourceApp
            payloads[metadata[index].id] = item.representations
            metadata[index].payloadSize = item.representations.reduce(0) { $0 + $1.data.count }
            metadata[index].recognizedText = item.recognizedText.nilIfEmpty
            metadata[index].barcodePayloads = item.barcodePayloads
            updateSortIndexes(for: metadata[index].id)
            if let thumbnailData = item.thumbnailData { thumbnails[metadata[index].id] = thumbnailData }
            payloadOCR.removeValue(forKey: metadata[index].id)
            payloadBarcodes.removeValue(forKey: metadata[index].id)
            refreshSearchDocument(metadata[index])
            dirtyPayloadIDs.insert(metadata[index].id)
            try enforceRetention(now: now)
            try save(writeIndex: !FileManager.default.fileExists(atPath: indexURL.path))
            scheduleIndexWrite()
            let saved = makeItem(metadata[index])
            publish(.updated(storeID: feedStoreID, item: saved))
            if saved.kind == .image { Task { await self.indexImageText(saved.id) } }
            return saved
        }

        var row = Metadata(
            id: item.id,
            contentHash: item.contentHash,
            kind: item.kind,
            preview: item.preview,
            createdAt: now,
            lastCopiedAt: now,
            lastUsedAt: now,
            useCount: 1,
            isPinned: false,
            isFavorite: false,
            collectionID: nil,
            title: nil,
            sourceApp: item.sourceApp
        )
        row.payloadSize = item.representations.reduce(0) { $0 + $1.data.count }
        row.recognizedText = item.recognizedText.nilIfEmpty
        row.barcodePayloads = item.barcodePayloads
        metadata.append(row)
        metadataIndexByID[row.id] = metadata.count - 1
        insertIntoSortIndexes(row.id)
        refreshSearchDocument(row)
        payloads[row.id] = item.representations
        if let thumbnailData = item.thumbnailData { thumbnails[row.id] = thumbnailData }
        dirtyPayloadIDs.insert(row.id)
        try enforceRetention(now: now)
        try save(writeIndex: !FileManager.default.fileExists(atPath: indexURL.path))
        scheduleIndexWrite()
        let saved = makeItem(row)
        publish(.inserted(storeID: feedStoreID, item: saved))
        if saved.kind == .image { Task { await self.indexImageText(saved.id) } }
        return saved
    }

    func captureBatch(_ items: [ClipboardItem], now: Date = Date()) throws -> [ClipboardItem] {
        try ensureLoaded()
        var inserted: [ClipboardItem] = []
        var changed = false
        for item in items {
            guard item.representations.reduce(0, { $0 + $1.data.count }) <= ClipboardHistorySettings.maximumItemSize(in: defaults) else { continue }
            guard ClipboardHistoryEngineSettings.shouldCapture(item.kind, defaults: defaults) else { continue }
            if let maximumSize = ClipboardHistoryEngineSettings.maximumSize(for: item.kind, defaults: defaults),
               item.representations.reduce(0, { $0 + $1.data.count }) > maximumSize { continue }
            if let index = metadata.firstIndex(where: { $0.contentHash == item.contentHash }) {
                changed = true
                metadata[index].lastUsedAt = now
                metadata[index].lastCopiedAt = now
                metadata[index].useCount += 1
                metadata[index].sourceApp = item.sourceApp
                metadata[index].recognizedText = item.recognizedText.nilIfEmpty
                metadata[index].barcodePayloads = item.barcodePayloads
                refreshSearchDocument(metadata[index])
                payloads[metadata[index].id] = item.representations
                if let thumbnailData = item.thumbnailData { thumbnails[metadata[index].id] = thumbnailData }
                dirtyPayloadIDs.insert(metadata[index].id)
                continue
            }
            var row = Metadata(
                id: item.id, contentHash: item.contentHash, kind: item.kind, preview: item.preview,
                createdAt: now, lastCopiedAt: now, lastUsedAt: now, useCount: 1,
                isPinned: false, isFavorite: false, collectionID: nil, title: nil,
                sourceApp: item.sourceApp
            )
            row.payloadSize = item.representations.reduce(0) { $0 + $1.data.count }
            row.recognizedText = item.recognizedText.nilIfEmpty
            row.barcodePayloads = item.barcodePayloads
            metadata.append(row)
            changed = true
            refreshSearchDocument(row)
            payloads[row.id] = item.representations
            if let thumbnailData = item.thumbnailData { thumbnails[row.id] = thumbnailData }
            dirtyPayloadIDs.insert(row.id)
            inserted.append(makeItem(row))
        }
        try enforceRetention(now: now)
        if changed { rebuildSortIndexes() }
        try save(writeIndex: false)
        scheduleIndexWrite()
        if !inserted.isEmpty { publish(.insertedBatch(storeID: feedStoreID, items: inserted)) }
        return inserted
    }

    /// Stores final dictated text only when the opt-in setting is enabled.
    func recordDictation(_ text: String, now: Date = Date()) throws -> ClipboardItem? {
        guard ClipboardHistorySettings.saveDictations,
              let item = ClipboardItem.capture(
                representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))],
                sourceApp: ClipboardSourceApp(bundleIdentifier: Bundle.main.bundleIdentifier, name: String(localized: "Zerm dictation")),
                createdAt: now
              ) else { return nil }
        let recorded = try capture(item, now: now)
        if let index = metadata.firstIndex(where: { $0.id == recorded.id }) {
            metadata[index].sourceApp = item.sourceApp
            try save()
        }
        return recorded
    }

    /// Returns items ordered by last use, newest first.
    func recent(limit: Int = 100) throws -> [ClipboardItem] {
        try ensureLoaded()
        return try metadata.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(max(0, limit)).map { try makePageItem($0) }
    }

    func recentPage(offset: Int = 0, limit: Int = 100) throws -> [ClipboardItem] {
        try ensureLoaded()
        let rows = metadata.sorted { $0.lastUsedAt > $1.lastUsedAt }
        let start = min(max(0, offset), rows.count)
        return try rows.dropFirst(start).prefix(max(0, limit)).map { try makePageItem($0) }
    }

    func totalCount() throws -> Int {
        try ensureLoaded()
        return metadata.count
    }

    func flushPendingWrites() throws {
        indexWriteTask?.cancel()
        indexWriteTask = nil
        try save()
    }

    /// Returns pinned items ordered by last use, newest first.
    func pinned() throws -> [ClipboardItem] {
        try ensureLoaded()
        return try metadata.filter(\.isPinned).sorted { $0.lastUsedAt > $1.lastUsedAt }.map { try makePageItem($0) }
    }

    func favorites() throws -> [ClipboardItem] {
        try ensureLoaded()
        return try metadata.filter(\.isFavorite).sorted { ($0.favoriteOrder ?? Int.max) < ($1.favoriteOrder ?? Int.max) }.map { try makePageItem($0) }
    }

    /// Searches previews, titles, and source app names, with an optional kind filter.
    func search(text: String = "", kind: ClipboardItemKind? = nil, limit: Int = 100) throws -> [ClipboardItem] {
        try ensureLoaded()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingIDs = searchIndex.matchingIDs(query: query, kind: kind)
        return try metadata
            .filter { matchingIDs.contains($0.id) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(max(0, limit))
            .map { try makePageItem($0) }
    }

    /// Pins or unpins an item; pinned items bypass count and age retention.
    func pin(_ id: UUID, pinned: Bool = true) throws {
        try ensureLoaded()
        guard let index = metadata.firstIndex(where: { $0.id == id }) else { return }
        metadata[index].isPinned = pinned
        try save()
        publishUpdated(id)
    }

    /// Marks an item as a favourite.
    func favorite(_ id: UUID, favorite: Bool = true) throws {
        try ensureLoaded()
        guard let index = metadata.firstIndex(where: { $0.id == id }) else { return }
        metadata[index].isFavorite = favorite
        if favorite, metadata[index].favoriteOrder == nil {
            metadata[index].favoriteOrder = (metadata.compactMap(\.favoriteOrder).max() ?? -1) + 1
        } else if !favorite {
            metadata[index].favoriteOrder = nil
        }
        try save()
        publishUpdated(id)
    }

    func reorderFavorites(_ ids: [UUID]) throws {
        try ensureLoaded()
        let favorites = metadata.filter(\.isFavorite)
        let favoriteIDs = Set(favorites.map(\.id))
        var ordered = ids.filter { favoriteIDs.contains($0) }
        let remaining = favorites
            .sorted { ($0.favoriteOrder ?? Int.max) < ($1.favoriteOrder ?? Int.max) }
            .map(\.id).filter { !ordered.contains($0) }
        ordered.append(contentsOf: remaining)
        for (order, id) in ordered.enumerated() {
            if let index = metadata.firstIndex(where: { $0.id == id }) { metadata[index].favoriteOrder = order }
        }
        try save()
    }

    /// Sets or clears a user's title.
    func rename(_ id: UUID, title: String?) throws {
        try ensureLoaded()
        guard let index = metadata.firstIndex(where: { $0.id == id }) else { return }
        metadata[index].title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        refreshSearchDocument(metadata[index])
        try save()
        publishUpdated(id)
    }

    /// Sets or clears optional collection membership.
    func setCollection(_ id: UUID, collectionID: UUID?) throws {
        try ensureLoaded()
        guard let index = metadata.firstIndex(where: { $0.id == id }) else { return }
        metadata[index].collectionID = collectionID
        try save()
        publishUpdated(id)
    }

    /// Deletes one item and its encrypted payload.
    func delete(_ id: UUID) throws {
        try ensureLoaded()
        let existed = metadata.contains { $0.id == id }
        let removed = removeItems([id])
        try save()
        if !removed.isEmpty { publish(.removed(storeID: feedStoreID, ids: removed)) }
        if existed { Task { @MainActor in SoundManager.shared.playClipboardDeleteSound() } }
    }

    func deleteItems(from bundleIdentifier: String) throws {
        try ensureLoaded()
        let removed = Set(metadata.filter { $0.sourceApp.bundleIdentifier == bundleIdentifier }.map(\.id))
        let removedIDs = removeItems(Array(removed))
        try save()
        if !removedIDs.isEmpty { publish(.removed(storeID: feedStoreID, ids: removedIDs)) }
        if !removed.isEmpty { Task { @MainActor in SoundManager.shared.playClipboardDeleteSound() } }
    }

    /// Keeps pinned items unless `includingPinned` is true.
    func clear(includingPinned: Bool = false, keepingFavorites: Bool? = nil, keepingTagged: Bool? = nil) throws {
        try ensureLoaded()
        let keepFavorites = keepingFavorites ?? ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepFavoritesOnClear, in: defaults, defaultValue: true)
        let keepTagged = keepingTagged ?? ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepTaggedOnClear, in: defaults, defaultValue: true)
        let protected: (Metadata) -> Bool = { row in
            (keepFavorites && row.isFavorite) || (keepTagged && !(row.tagIDs ?? []).isEmpty)
        }
        let removed = metadata.filter { row in !(protected(row) || (!includingPinned && row.isPinned)) }.map(\.id)
        let removedIDs = removeItems(removed)
        try save()
        if !removedIDs.isEmpty {
            publish(.cleared(storeID: feedStoreID, removedIDs: removedIDs))
            Task { @MainActor in SoundManager.shared.playClipboardDeleteSound() }
        }
    }

    func archiveEntries() throws -> [ClipboardHistoryArchive.Entry] {
        try ensureLoaded()
        return metadata.compactMap { row in
            guard let representations = try? loadPayload(row.id).representations else { return nil }
            return ClipboardHistoryArchive.Entry(item: makeItem(row, representations: representations), favoriteOrder: row.favoriteOrder)
        }
    }

    func mergeArchiveEntries(_ entries: [ClipboardHistoryArchive.Entry]) throws {
        try ensureLoaded()
        var archivedTagIDs: [UUID: UUID] = [:]
        for tag in entries.flatMap({ $0.item.tagDefinitions ?? [] }) {
            if let existing = tags.first(where: { $0.name.localizedCaseInsensitiveCompare(tag.name) == .orderedSame }) {
                archivedTagIDs[tag.id] = existing.id
            } else {
                let id = tags.contains(where: { $0.id == tag.id }) ? UUID() : tag.id
                tags.append(ClipboardTag(id: id, name: tag.name, colorHex: tag.colorHex))
                archivedTagIDs[tag.id] = id
                tagsDirty = true
            }
        }
        for entry in entries {
            var imported = entry.item
            imported.tagIDs = imported.tagIDs.compactMap { archivedTagIDs[$0] }
            let importedSize = imported.representations.reduce(0) { $0 + $1.data.count }
            guard importedSize <= ClipboardHistorySettings.maximumItemSize(in: defaults),
                  ClipboardHistoryEngineSettings.maximumSize(for: imported.kind, defaults: defaults).map({ importedSize <= $0 }) ?? true else { continue }
            if let existingIndex = metadata.firstIndex(where: { $0.contentHash == imported.contentHash }) {
                let existingID = metadata[existingIndex].id
                metadata[existingIndex].isPinned = metadata[existingIndex].isPinned || imported.isPinned
                metadata[existingIndex].isFavorite = metadata[existingIndex].isFavorite || imported.isFavorite
                if metadata[existingIndex].title == nil { metadata[existingIndex].title = imported.title }
                if metadata[existingIndex].collectionID == nil { metadata[existingIndex].collectionID = imported.collectionID }
                if metadata[existingIndex].favoriteOrder == nil { metadata[existingIndex].favoriteOrder = entry.favoriteOrder }
                metadata[existingIndex].tagIDs = Array(Set((metadata[existingIndex].tagIDs ?? []) + imported.tagIDs))
                metadata[existingIndex].createdAt = min(metadata[existingIndex].createdAt, imported.createdAt)
                metadata[existingIndex].lastCopiedAt = max(metadata[existingIndex].lastCopiedAt ?? imported.lastCopiedAt, imported.lastCopiedAt)
                metadata[existingIndex].lastUsedAt = max(metadata[existingIndex].lastUsedAt, imported.lastUsedAt)
                metadata[existingIndex].useCount = max(metadata[existingIndex].useCount, imported.useCount)
                if payloads[existingID] == nil { payloads[existingID] = imported.representations; dirtyPayloadIDs.insert(existingID) }
                continue
            }

            let importedID = metadata.contains(where: { $0.id == imported.id }) ? UUID() : imported.id
            metadata.append(Metadata(
                id: importedID,
                contentHash: imported.contentHash,
                kind: imported.kind,
                preview: imported.preview,
                createdAt: imported.createdAt,
                lastCopiedAt: imported.lastCopiedAt,
                lastUsedAt: imported.lastUsedAt,
                useCount: imported.useCount,
                isPinned: imported.isPinned,
                isFavorite: imported.isFavorite,
                collectionID: imported.collectionID,
                title: imported.title,
                tagIDs: imported.tagIDs,
                favoriteOrder: entry.favoriteOrder,
                sourceApp: imported.sourceApp
            ))
            payloads[importedID] = imported.representations
            payloadOCR[importedID] = imported.recognizedText
            payloadBarcodes[importedID] = imported.barcodePayloads
            dirtyPayloadIDs.insert(importedID)
        }
        try enforceRetention(now: Date())
        rebuildSortIndexes()
        refreshAllSearchDocuments()
        try save()
    }

    func storageSize() throws -> Int64 {
        try ensureLoaded()
        let files = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func itemWithPayload(_ id: UUID) throws -> ClipboardItem {
        try ensureLoaded()
        guard let row = metadata.first(where: { $0.id == id }) else { throw ClipboardHistoryError.missingPayload }
        let payload = try loadPayload(id)
        return makeItem(row, representations: payload.representations)
    }

    /// Pastes the original representations, or extracts full plain text from the stored payload.
    func paste(_ item: ClipboardItem, asPlainText: Bool = false) async throws {
        try ensureLoaded()
        guard let stored = metadata.first(where: { $0.id == item.id }) else { throw ClipboardHistoryError.missingPayload }
        let representations = try loadPayload(stored.id).representations
        let selected = asPlainText
            ? [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(ClipboardPanelText.plainText(from: representations, fallback: stored.preview).utf8))]
            : representations
        try await CursorPaster.pasteClipboardHistoryItem(selected)
        if ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.updateAfterPaste),
           let index = metadata.firstIndex(where: { $0.id == stored.id }) {
            metadata[index].lastUsedAt = Date()
            metadata[index].useCount += 1
            updateSortIndexes(for: stored.id)
            try save()
        }
    }

    func allTags() throws -> [ClipboardTag] {
        try ensureLoaded()
        return tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func createTag(name: String, colorHex: String = "#808080") throws -> ClipboardTag {
        try ensureLoaded()
        let tag = ClipboardTag(name: name, colorHex: colorHex)
        tags.append(tag)
        tagsDirty = true
        try save()
        return tag
    }

    func renameTag(_ id: UUID, name: String) throws {
        try ensureLoaded()
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tagsDirty = true
        refreshAllSearchDocuments()
        try save()
    }

    func recolorTag(_ id: UUID, colorHex: String) throws {
        try ensureLoaded()
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[index].colorHex = colorHex
        tagsDirty = true
        try save()
    }

    func deleteTag(_ id: UUID) throws {
        try ensureLoaded()
        tags.removeAll { $0.id == id }
        tagsDirty = true
        for index in metadata.indices { metadata[index].tagIDs?.removeAll { $0 == id } }
        refreshAllSearchDocuments()
        try save()
    }

    func attachTag(_ tagID: UUID, to itemID: UUID) throws {
        try ensureLoaded()
        guard tags.contains(where: { $0.id == tagID }), let index = metadata.firstIndex(where: { $0.id == itemID }) else { return }
        var tagIDs = metadata[index].tagIDs ?? []
        if !tagIDs.contains(tagID) { tagIDs.append(tagID) }
        metadata[index].tagIDs = tagIDs
        tagsDirty = true
        refreshSearchDocument(metadata[index])
        try save()
        publishUpdated(itemID)
    }

    func detachTag(_ tagID: UUID, from itemID: UUID) throws {
        try ensureLoaded()
        guard let index = metadata.firstIndex(where: { $0.id == itemID }) else { return }
        metadata[index].tagIDs?.removeAll { $0 == tagID }
        tagsDirty = true
        refreshSearchDocument(metadata[index])
        try save()
        publishUpdated(itemID)
    }

    func search(tagID: UUID, limit: Int = 100) throws -> [ClipboardItem] {
        try ensureLoaded()
        return try metadata.filter { $0.tagIDs?.contains(tagID) == true }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(max(0, limit)).map { try makePageItem($0) }
    }

    func sorted(_ order: ClipboardHistorySort, ascending: Bool = false, limit: Int = 100) throws -> [ClipboardItem] {
        try ensureLoaded()
        let rows = try sortedRows(order, ascending: ascending)
        return try Array(rows.prefix(max(0, limit))).map { try makePageItem($0) }
    }

    private func sortedRows(_ order: ClipboardHistorySort, ascending: Bool) throws -> [Metadata] {
        try ensureLoaded()
        let ids = sortOrderIDs[sortKey(for: order)] ?? []
        let orderedIDs = ascending ? ids : ids.reversed()
        return orderedIDs.compactMap { id in metadataIndexByID[id].map { metadata[$0] } }
    }

    private func sortKey(for order: ClipboardHistorySort) -> SortKey {
        switch order {
        case .lastCopy: return .lastCopy
        case .firstCopy, .copySequence: return .firstCopy
        case .copyCount: return .copyCount
        case .size: return .size
        }
    }

    private func comesBefore(_ leftID: UUID, _ rightID: UUID, for key: SortKey) -> Bool {
        guard let leftIndex = metadataIndexByID[leftID], let rightIndex = metadataIndexByID[rightID] else { return leftID.uuidString < rightID.uuidString }
        let left = metadata[leftIndex]
        let right = metadata[rightIndex]
        let result: ComparisonResult
        switch key {
        case .lastCopy:
            result = (left.lastCopiedAt ?? left.lastUsedAt).compare(right.lastCopiedAt ?? right.lastUsedAt)
        case .firstCopy:
            result = left.createdAt.compare(right.createdAt)
        case .copyCount:
            result = left.useCount == right.useCount ? .orderedSame : (left.useCount < right.useCount ? .orderedAscending : .orderedDescending)
        case .size:
            let lhs = left.payloadSize ?? 0
            let rhs = right.payloadSize ?? 0
            result = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
        return result == .orderedSame ? left.id.uuidString < right.id.uuidString : result == .orderedAscending
    }

    private func rebuildMetadataIndex() {
        metadataIndexByID = Dictionary(uniqueKeysWithValues: metadata.enumerated().map { ($0.element.id, $0.offset) })
    }

    private func rebuildSortIndexes() {
        rebuildMetadataIndex()
        for key in SortKey.allCases {
            sortOrderIDs[key] = metadata.map(\.id).sorted { comesBefore($0, $1, for: key) }
        }
    }

    private func insertIntoSortIndexes(_ id: UUID) {
        for key in SortKey.allCases {
            guard var ids = sortOrderIDs[key] else { continue }
            var low = 0
            var high = ids.count
            while low < high {
                let middle = (low + high) / 2
                if comesBefore(ids[middle], id, for: key) { low = middle + 1 }
                else { high = middle }
            }
            ids.insert(id, at: low)
            sortOrderIDs[key] = ids
        }
    }

    private func updateSortIndexes(for id: UUID) {
        for key in SortKey.allCases {
            guard var ids = sortOrderIDs[key], let oldIndex = ids.firstIndex(of: id) else { continue }
            ids.remove(at: oldIndex)
            sortOrderIDs[key] = ids
            insertIntoSortIndex(id, for: key)
        }
    }

    private func insertIntoSortIndex(_ id: UUID, for key: SortKey) {
        guard var ids = sortOrderIDs[key] else { return }
        var low = 0
        var high = ids.count
        while low < high {
            let middle = (low + high) / 2
            if comesBefore(ids[middle], id, for: key) { low = middle + 1 }
            else { high = middle }
        }
        ids.insert(id, at: low)
        sortOrderIDs[key] = ids
    }

    func sortedPage(_ order: ClipboardHistorySort, ascending: Bool = false, offset: Int, limit: Int) throws -> [ClipboardItem] {
        try ensureLoaded()
        let ids = sortOrderIDs[sortKey(for: order)] ?? []
        let start = min(max(0, offset), ids.count)
        let end = min(start + max(0, limit), ids.count)
        let pageIDs = ascending
            ? Array(ids[start..<end])
            : Array(ids[(ids.count - end)..<(ids.count - start)].reversed())
        let rows = pageIDs.compactMap { id in metadataIndexByID[id].map { metadata[$0] } }
        return try rows.map { try makePageItem($0) }
    }

    func cleanupExpired(now: Date = Date()) throws {
        try ensureLoaded()
        try enforceRetention(now: now)
        try save()
    }

    func shouldCapture(_ kind: ClipboardItemKind) -> Bool {
        ClipboardHistoryEngineSettings.shouldCapture(kind, defaults: defaults)
    }

    func pasteNext(
        asPlainText: Bool = true,
        operation: ClipboardHistoryPasteOperation? = nil
    ) async throws -> ClipboardItem? {
        guard let item = try nextPasteCandidate() else { return nil }
        if let operation { try await operation(item, asPlainText) }
        else { try await paste(item, asPlainText: asPlainText) }
        try recordPasteSequenceSuccess(item.id)
        return item
    }

    func nextPasteCandidate() throws -> ClipboardItem? {
        try ensureLoaded()
        let candidates = metadata.filter { !$0.isFavorite }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        guard !candidates.isEmpty else { pasteSequenceLastID = nil; return nil }
        let next: Metadata
        if let lastID = pasteSequenceLastID, let index = candidates.firstIndex(where: { $0.id == lastID }) {
            next = candidates[(index + 1) % candidates.count]
        } else {
            next = candidates[0]
        }
        return makeItem(next)
    }

    func recordPasteSequenceSuccess(_ id: UUID) throws {
        try ensureLoaded()
        guard metadata.contains(where: { $0.id == id && !$0.isFavorite }) else { return }
        pasteSequenceLastID = id
        try save()
    }

    func pasteNextFormatted(operation: ClipboardHistoryPasteOperation? = nil) async throws -> ClipboardItem? {
        try await pasteNext(asPlainText: false, operation: operation)
    }

    func resetPasteSequence() { pasteSequenceLastID = nil }

    func merge(_ ids: [UUID], separator: String = "\n", now: Date = Date()) throws -> ClipboardItem? {
        try ensureLoaded()
        let selected = ids.compactMap { id in metadata.first(where: { $0.id == id }) }
            .filter { [.plainText, .richText, .url, .email, .color].contains($0.kind) }
        guard selected.count >= 2 else { return nil }
        let value = selected.map(\.preview).joined(separator: separator)
        guard let item = ClipboardItem.capture(
            representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))],
            sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil), createdAt: now
        ) else { return nil }
        let merged = try capture(item, now: now)
        removeItems(selected.map(\.id))
        try save()
        return merged
    }

    func split(_ id: UUID, now: Date = Date()) throws -> [ClipboardItem] {
        try ensureLoaded()
        guard let row = metadata.first(where: { $0.id == id }), [.plainText, .richText].contains(row.kind) else { return [] }
        let lines = row.preview.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return try lines.enumerated().compactMap { index, line in
            guard let item = ClipboardItem.capture(
                representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(line.utf8))],
                sourceApp: row.sourceApp, createdAt: now.addingTimeInterval(Double(index) / 1000)
            ) else { return nil }
            return try capture(item, now: now.addingTimeInterval(Double(index) / 1000))
        }
    }

    func edit(_ id: UUID, representations: [ClipboardRepresentation]) throws -> ClipboardItem? {
        try ensureLoaded()
        guard let index = metadata.firstIndex(where: { $0.id == id }),
              let replacement = ClipboardItem.capture(representations: representations, sourceApp: metadata[index].sourceApp) else { return nil }
        let replacementSize = replacement.representations.reduce(0) { $0 + $1.data.count }
        guard replacementSize <= ClipboardHistorySettings.maximumItemSize(in: defaults),
              ClipboardHistoryEngineSettings.maximumSize(for: replacement.kind, defaults: defaults).map({ replacementSize <= $0 }) ?? true else {
            throw ClipboardHistoryStoreCaptureError.itemTooLarge
        }
        metadata[index].contentHash = replacement.contentHash
        metadata[index].kind = replacement.kind
        metadata[index].preview = replacement.preview
        metadata[index].payloadSize = replacement.representations.reduce(0) { $0 + $1.data.count }
        updateSortIndexes(for: id)
        refreshSearchDocument(metadata[index])
        payloads[id] = replacement.representations
        payloadOCR.removeValue(forKey: id)
        payloadBarcodes.removeValue(forKey: id)
        dirtyPayloadIDs.insert(id)
        try enforceRetention(now: Date())
        try save()
        guard metadata.contains(where: { $0.id == id }) else { return nil }
        publishUpdated(id)
        return makeItem(metadata[index])
    }

    func editText(_ id: UUID, text: String, richText: Bool = false) throws -> ClipboardItem? {
        let representation: ClipboardRepresentation
        if richText {
            let attributed = NSAttributedString(string: text)
            let range = NSRange(location: 0, length: (text as NSString).length)
            let data = (try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data(text.utf8)
            representation = ClipboardRepresentation(type: "public.rtf", data: data)
        } else {
            representation = ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
        }
        return try edit(id, representations: [representation])
    }

    func appendCopyToPreviousText(_ text: String, separator: String = "\n") throws -> ClipboardItem? {
        try ensureLoaded()
        guard let row = metadata.filter({ !$0.isFavorite && $0.kind == .plainText }).max(by: { $0.lastUsedAt < $1.lastUsedAt }) else { return nil }
        return try editText(row.id, text: row.preview + separator + text)
    }

    func indexImageText(_ id: UUID) async {
        guard (try? ensureLoaded()) != nil,
              let row = metadata.first(where: { $0.id == id }), row.kind == .image,
              !indexingImageIDs.contains(id),
              row.recognizedText == nil,
              let data = try? loadPayload(id).representations.first(where: { ["public.tiff", "public.png", "public.jpeg"].contains($0.type) })?.data else { return }
        indexingImageIDs.insert(id)
        defer { indexingImageIDs.remove(id) }
        let result = await ClipboardImageAnalyzer.analyze(data)
        guard metadata.first(where: { $0.id == id })?.contentHash == row.contentHash else { return }
        guard let index = metadata.firstIndex(where: { $0.id == id }) else { return }
        payloadOCR[id] = result.recognizedText
        payloadBarcodes[id] = result.barcodePayloads
        metadata[index].recognizedText = result.recognizedText
        metadata[index].barcodePayloads = result.barcodePayloads
        refreshSearchDocument(metadata[index])
        try? save()
    }

    private func removeItems(_ ids: [UUID]) -> [UUID] {
        let removed = Set(ids)
        if let pasteSequenceLastID, removed.contains(pasteSequenceLastID) { resetPasteSequence() }
        metadata.removeAll { removed.contains($0.id) }
        for key in SortKey.allCases { sortOrderIDs[key]?.removeAll { removed.contains($0) } }
        rebuildMetadataIndex()
        searchIndex.remove(removed)
        for id in removed {
            payloads.removeValue(forKey: id)
            payloadOCR.removeValue(forKey: id)
            payloadBarcodes.removeValue(forKey: id)
            thumbnails.removeValue(forKey: id)
            dirtyPayloadIDs.remove(id)
            pendingBlobDeletes.insert(id)
        }
        return Array(removed)
    }

    private func makeItem(_ row: Metadata, representations: [ClipboardRepresentation]? = nil) -> ClipboardItem {
        let tagIDs = row.tagIDs ?? []
        return ClipboardItem(
            id: row.id,
            contentHash: row.contentHash,
            kind: row.kind,
            representations: representations ?? [],
            thumbnailData: thumbnails[row.id],
            payloadSize: row.payloadSize,
            preview: row.preview,
            createdAt: row.createdAt,
            lastCopiedAt: row.lastCopiedAt ?? row.lastUsedAt,
            lastUsedAt: row.lastUsedAt,
            useCount: row.useCount,
            isPinned: row.isPinned,
            isFavorite: row.isFavorite,
            collectionID: row.collectionID,
            title: row.title,
            tagIDs: tagIDs,
            tagDefinitions: tags.filter { tagIDs.contains($0.id) },
            recognizedText: row.recognizedText ?? payloadOCR[row.id] ?? "",
            barcodePayloads: row.barcodePayloads ?? payloadBarcodes[row.id] ?? [],
            sourceApp: row.sourceApp
        )
    }

    private func enforceRetention(now: Date) throws {
        let oversized = metadata.filter { ($0.payloadSize ?? 0) > ClipboardHistorySettings.maximumItemSize(in: defaults) }.map(\.id)
        removeItems(oversized)
        let keepFavorites = ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepFavoritesOnClear, in: defaults, defaultValue: true)
        let keepTagged = ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepTaggedOnClear, in: defaults, defaultValue: true)
        let expired = metadata.filter { row in
            guard !row.isPinned,
                  !(keepFavorites && row.isFavorite),
                  !(keepTagged && !(row.tagIDs ?? []).isEmpty) else { return false }
            let period = ClipboardHistoryEngineSettings.retentionPeriod(for: row.kind, defaults: defaults)
            guard let days = period.dayCount else { return period == .never }
            return (row.lastCopiedAt ?? row.lastUsedAt) < now.addingTimeInterval(-Double(days) * 86_400)
        }.map(\.id)
        removeItems(expired)
        let unpinned = metadata.filter {
            !$0.isPinned
                && !(keepFavorites && $0.isFavorite)
                && !(keepTagged && !($0.tagIDs ?? []).isEmpty)
        }
        let retentionCount = ClipboardHistorySettings.retentionCount(in: defaults)
        if unpinned.count > retentionCount {
            let excess = Set(unpinned.sorted { $0.lastUsedAt > $1.lastUsedAt }.dropFirst(retentionCount).map(\.id))
            removeItems(Array(excess))
        }
        enforceSizeLimits()
    }

    private func enforceSizeLimits() {
        var eligible: [Metadata]?
        func evictionOrder() -> [Metadata] {
            if let eligible { return eligible }
            let ordered = metadata.filter { !$0.isPinned }.sorted {
                let leftProtected = $0.isFavorite || !($0.tagIDs ?? []).isEmpty
                let rightProtected = $1.isFavorite || !($1.tagIDs ?? []).isEmpty
                if leftProtected != rightProtected { return !leftProtected }
                return $0.lastUsedAt < $1.lastUsedAt
            }
            eligible = ordered
            return ordered
        }
        for kind in ClipboardItemKind.allCases {
            guard let limit = ClipboardHistoryEngineSettings.maximumSize(for: kind, defaults: defaults) else { continue }
            let kindItems = metadata.filter { $0.kind == kind }
            var remaining = kindItems.reduce(0) { $0 + ($1.payloadSize ?? 0) }
            guard remaining > limit else { continue }
            for row in evictionOrder().filter({ $0.kind == kind }) where remaining > limit {
                removeItems([row.id])
                remaining -= row.payloadSize ?? 0
            }
        }

        var remaining = metadata.reduce(0) { $0 + ($1.payloadSize ?? 0) }
        let totalLimit = ClipboardHistorySettings.maximumStorageSize(in: defaults)
        guard remaining > totalLimit else { return }
        for row in evictionOrder() where remaining > totalLimit {
            guard metadata.contains(where: { $0.id == row.id }) else { continue }
            removeItems([row.id])
            remaining -= row.payloadSize ?? 0
        }
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let encryptedIndex = try Data(contentsOf: indexURL)
            metadata = try JSONDecoder().decode([Metadata].self, from: encryption.open(encryptedIndex))
            if FileManager.default.fileExists(atPath: tagsURL.path) {
                tags = try JSONDecoder().decode([ClipboardTag].self, from: encryption.open(Data(contentsOf: tagsURL)))
            }
            if FileManager.default.fileExists(atPath: searchIndexURL.path) {
                searchIndex = try JSONDecoder().decode(ClipboardHistorySearchIndex.self, from: encryption.open(Data(contentsOf: searchIndexURL)))
            } else {
                for row in metadata {
                    let payload = try loadPayload(row.id)
                    if let index = metadata.firstIndex(where: { $0.id == row.id }) {
                        metadata[index].payloadSize = row.payloadSize ?? payload.representations.reduce(0) { $0 + $1.data.count }
                        metadata[index].recognizedText = payload.recognizedText
                        metadata[index].barcodePayloads = payload.barcodePayloads
                    }
                }
                refreshAllSearchDocuments()
                try save()
            }
            if FileManager.default.fileExists(atPath: sortIndexURL.path),
               let savedOrders = try? JSONDecoder().decode([SortKey: [UUID]].self, from: encryption.open(Data(contentsOf: sortIndexURL))) {
                let itemIDs = Set(metadata.map(\.id))
                if savedOrders.count == SortKey.allCases.count,
                   SortKey.allCases.allSatisfy({ key in
                       guard let ids = savedOrders[key] else { return false }
                       return ids.count == metadata.count && Set(ids) == itemIDs
                   }) {
                    sortOrderIDs = savedOrders
                    rebuildMetadataIndex()
                    let indexesAreOrdered = SortKey.allCases.allSatisfy { key in
                        guard let ids = sortOrderIDs[key] else { return false }
                        return zip(ids, ids.dropFirst()).allSatisfy { comesBefore($0.0, $0.1, for: key) }
                    }
                    if !indexesAreOrdered { sortOrderIDs.removeAll() }
                }
            }
            let previousIDs = Set(metadata.map(\.id))
            try enforceRetention(now: Date())
            if Set(metadata.map(\.id)) != previousIDs { try save() }
        } catch {
            throw ClipboardHistoryError.corruptStore
        }
    }

    private func ensureLoaded() throws {
        guard !hasLoaded else { return }
        try load()
        hasLoaded = true
        if sortOrderIDs.count == SortKey.allCases.count { rebuildMetadataIndex() }
        else { rebuildSortIndexes() }
    }

    private func save(writeIndex: Bool = true) throws {
        if writeIndex {
            indexWriteTask?.cancel()
            indexWriteTask = nil
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let activeIDs = Set(metadata.map(\.id))
        for id in dirtyPayloadIDs {
            guard activeIDs.contains(id), let representations = payloads[id] else { continue }
            let payload = try encoder.encode(Payload(
                representations: representations,
                thumbnailData: thumbnails[id],
                recognizedText: payloadOCR[id],
                barcodePayloads: payloadBarcodes[id]
            ))
            let encrypted = try encryption.seal(payload)
            try encrypted.write(to: directoryURL.appendingPathComponent("\(id.uuidString).blob.enc"), options: .atomic)
            if let thumbnailData = thumbnails[id] {
                try encryption.seal(thumbnailData).write(
                    to: directoryURL.appendingPathComponent("\(id.uuidString).thumb.enc"), options: .atomic
                )
            }
            payloads.removeValue(forKey: id)
        }
        for id in pendingBlobDeletes where !activeIDs.contains(id) {
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent("\(id.uuidString).blob.enc"))
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent("\(id.uuidString).thumb.enc"))
        }
        pendingBlobDeletes.removeAll()
        if writeIndex {
            try encryption.seal(encoder.encode(metadata)).write(to: indexURL, options: .atomic)
            try encryption.seal(encoder.encode(searchIndex)).write(to: searchIndexURL, options: .atomic)
            try encryption.seal(encoder.encode(sortOrderIDs)).write(to: sortIndexURL, options: .atomic)
        }
        if tagsDirty {
            try encryption.seal(encoder.encode(tags)).write(to: tagsURL, options: .atomic)
            tagsDirty = false
        }
        dirtyPayloadIDs.removeAll()
    }

    private func scheduleIndexWrite() {
        indexWriteTask?.cancel()
        indexWriteTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            try? self.save()
            self.indexWriteTask = nil
        }
    }

    private func publish(_ change: ClipboardHistoryChange) {
        Task { @MainActor in ClipboardHistoryFeed.shared.publish(change) }
    }

    private func publishUpdated(_ id: UUID) {
        guard let row = metadata.first(where: { $0.id == id }) else { return }
        publish(.updated(storeID: feedStoreID, item: makeItem(row)))
    }

    private func loadPayload(_ id: UUID) throws -> Payload {
        if let representations = payloads[id] {
            return Payload(
                representations: representations, thumbnailData: thumbnails[id],
                recognizedText: payloadOCR[id], barcodePayloads: payloadBarcodes[id]
            )
        }
        let url = directoryURL.appendingPathComponent("\(id.uuidString).blob.enc")
        guard FileManager.default.fileExists(atPath: url.path) else { throw ClipboardHistoryError.missingPayload }
        do {
            let decrypted = try encryption.open(Data(contentsOf: url))
            return try JSONDecoder().decode(Payload.self, from: decrypted)
        } catch {
            throw ClipboardHistoryError.corruptStore
        }
    }

    private func makePageItem(_ row: Metadata) throws -> ClipboardItem {
        if row.kind == .image, thumbnails[row.id] == nil { thumbnails[row.id] = try loadThumbnail(row.id) }
        return makeItem(row)
    }

    private func loadThumbnail(_ id: UUID) throws -> Data? {
        let url = directoryURL.appendingPathComponent("\(id.uuidString).thumb.enc")
        if FileManager.default.fileExists(atPath: url.path) {
            return try encryption.open(Data(contentsOf: url))
        }
        let payload = try loadPayload(id)
        guard let thumbnailData = payload.thumbnailData else { return nil }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encryption.seal(thumbnailData).write(to: url, options: .atomic)
        return thumbnailData
    }

    private func refreshAllSearchDocuments() {
        searchIndex = ClipboardHistorySearchIndex()
        for row in metadata { refreshSearchDocument(row) }
    }

    private func refreshSearchDocument(_ row: Metadata) {
        let tagNames = tags.filter { row.tagIDs?.contains($0.id) == true }.map(\.name)
        searchIndex.update(
            id: row.id,
            kind: row.kind,
            fields: [row.preview, row.title ?? "", row.sourceApp.name ?? "", row.sourceApp.bundleIdentifier ?? "",
                     row.recognizedText ?? payloadOCR[row.id] ?? "", (row.barcodePayloads ?? payloadBarcodes[row.id] ?? []).joined(separator: " "),
                     tagNames.joined(separator: " "), row.kind.rawValue]
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
