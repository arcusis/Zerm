import AppKit
import CryptoKit
import Foundation

typealias ClipboardHistoryPasteOperation = @Sendable (ClipboardItem, Bool) async throws -> Void

/// Local encrypted clipboard history. Every public operation is asynchronous and serialized by the actor.
actor ClipboardHistoryStore {
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
        var sourceApp: ClipboardSourceApp
    }

    private struct Payload: Codable {
        let representations: [ClipboardRepresentation]
        var recognizedText: String?
        var barcodePayloads: [String]?
    }

    private let directoryURL: URL
    private let indexURL: URL
    private let tagsURL: URL
    private let encryption: ClipboardHistoryEncryption
    private var metadata: [Metadata]
    private var payloads: [UUID: [ClipboardRepresentation]]
    private var dirtyPayloadIDs: Set<UUID>
    private var hasLoaded = false
    private var tags: [ClipboardTag] = []
    private var payloadOCR: [UUID: String] = [:]
    private var payloadBarcodes: [UUID: [String]] = [:]
    private var pasteSequenceLastID: UUID?
    private var indexingImageIDs: Set<UUID> = []

    /// Tests pass a temporary directory and random key. Live installs use a unique Keychain key.
    init(directoryURL: URL = AppStoragePaths.root.appendingPathComponent("ClipboardHistory", isDirectory: true), keyData: Data? = nil) throws {
        self.directoryURL = directoryURL
        indexURL = directoryURL.appendingPathComponent("index.enc")
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
        guard ClipboardHistoryEngineSettings.shouldCapture(item.kind) else { throw ClipboardHistoryCaptureError.retentionDisabled }
        if let index = metadata.firstIndex(where: { $0.contentHash == item.contentHash }) {
            metadata[index].lastUsedAt = now
            metadata[index].lastCopiedAt = now
            metadata[index].useCount += 1
            metadata[index].sourceApp = item.sourceApp
            payloads[metadata[index].id] = item.representations
            payloadOCR.removeValue(forKey: metadata[index].id)
            payloadBarcodes.removeValue(forKey: metadata[index].id)
            dirtyPayloadIDs.insert(metadata[index].id)
            try enforceRetention(now: now)
            try save()
            let saved = makeItem(metadata[index])
            if saved.kind == .image { Task { await self.indexImageText(saved.id) } }
            return saved
        }

        let row = Metadata(
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
        metadata.append(row)
        payloads[row.id] = item.representations
        dirtyPayloadIDs.insert(row.id)
        try enforceRetention(now: now)
        try save()
        let saved = makeItem(row)
        if saved.kind == .image { Task { await self.indexImageText(saved.id) } }
        return saved
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
        return metadata.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(max(0, limit)).map { makeItem($0) }
    }

    /// Returns pinned items ordered by last use, newest first.
    func pinned() throws -> [ClipboardItem] {
        try ensureLoaded()
        return metadata.filter(\.isPinned).sorted { $0.lastUsedAt > $1.lastUsedAt }.map { makeItem($0) }
    }

    func favorites() throws -> [ClipboardItem] {
        try ensureLoaded()
        return metadata.filter(\.isFavorite).sorted { ($0.favoriteOrder ?? Int.max) < ($1.favoriteOrder ?? Int.max) }.map { makeItem($0) }
    }

    /// Searches previews, titles, and source app names, with an optional kind filter.
    func search(text: String = "", kind: ClipboardItemKind? = nil, limit: Int = 100) throws -> [ClipboardItem] {
        try ensureLoaded()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return metadata
            .filter { row in
                let tagNames = tags.filter { row.tagIDs?.contains($0.id) == true }.map(\.name).joined(separator: " ")
                return (kind == nil || row.kind == kind)
                    && (query.isEmpty || ([row.preview, row.title ?? "", row.sourceApp.name ?? "", tagNames, payloadOCR[row.id] ?? "", (payloadBarcodes[row.id] ?? []).joined(separator: " ")].contains { $0.localizedLowercase.contains(query) }))
            }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(max(0, limit))
            .map { makeItem($0) }
    }

    /// Pins or unpins an item; pinned items bypass count and age retention.
    func pin(_ id: UUID, pinned: Bool = true) throws {
        try ensureLoaded()
        guard let index = metadata.firstIndex(where: { $0.id == id }) else { return }
        metadata[index].isPinned = pinned
        try save()
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
        try save()
    }

    /// Sets or clears optional collection membership.
    func setCollection(_ id: UUID, collectionID: UUID?) throws {
        try ensureLoaded()
        guard let index = metadata.firstIndex(where: { $0.id == id }) else { return }
        metadata[index].collectionID = collectionID
        try save()
    }

    /// Deletes one item and its encrypted payload.
    func delete(_ id: UUID) throws {
        try ensureLoaded()
        let existed = metadata.contains { $0.id == id }
        removeItems([id])
        try save()
        if existed { Task { @MainActor in SoundManager.shared.playClipboardDeleteSound() } }
    }

    func deleteItems(from bundleIdentifier: String) throws {
        try ensureLoaded()
        let removed = Set(metadata.filter { $0.sourceApp.bundleIdentifier == bundleIdentifier }.map(\.id))
        removeItems(Array(removed))
        try save()
        if !removed.isEmpty { Task { @MainActor in SoundManager.shared.playClipboardDeleteSound() } }
    }

    /// Keeps pinned items unless `includingPinned` is true.
    func clear(includingPinned: Bool = false, keepingFavorites: Bool? = nil, keepingTagged: Bool? = nil) throws {
        try ensureLoaded()
        let keepFavorites = keepingFavorites ?? ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepFavoritesOnClear, defaultValue: true)
        let keepTagged = keepingTagged ?? ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepTaggedOnClear, defaultValue: true)
        let protected: (Metadata) -> Bool = { row in
            (keepFavorites && row.isFavorite) || (keepTagged && !(row.tagIDs ?? []).isEmpty)
        }
        let removed = metadata.filter { row in !(protected(row) || (!includingPinned && row.isPinned)) }.map(\.id)
        removeItems(removed)
        try save()
        if !removed.isEmpty { Task { @MainActor in SoundManager.shared.playClipboardDeleteSound() } }
    }

    func archiveEntries() throws -> [ClipboardHistoryArchive.Entry] {
        try ensureLoaded()
        return metadata.compactMap { row in
            guard let representations = payloads[row.id] else { return nil }
            return ClipboardHistoryArchive.Entry(item: makeItem(row, representations: representations), favoriteOrder: row.favoriteOrder)
        }
    }

    func mergeArchiveEntries(_ entries: [ClipboardHistoryArchive.Entry]) throws {
        try ensureLoaded()
        for entry in entries {
            let imported = entry.item
            if let existingIndex = metadata.firstIndex(where: { $0.contentHash == imported.contentHash }) {
                let existingID = metadata[existingIndex].id
                metadata[existingIndex].isPinned = metadata[existingIndex].isPinned || imported.isPinned
                metadata[existingIndex].isFavorite = metadata[existingIndex].isFavorite || imported.isFavorite
                if metadata[existingIndex].title == nil { metadata[existingIndex].title = imported.title }
                if metadata[existingIndex].collectionID == nil { metadata[existingIndex].collectionID = imported.collectionID }
                if metadata[existingIndex].favoriteOrder == nil { metadata[existingIndex].favoriteOrder = entry.favoriteOrder }
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
        try save()
    }

    func storageSize() throws -> Int64 {
        try ensureLoaded()
        let files = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Pastes the original representations, or extracts full plain text from the stored payload.
    func paste(_ item: ClipboardItem, asPlainText: Bool = false) async throws {
        try ensureLoaded()
        guard let stored = metadata.first(where: { $0.id == item.id }),
              let representations = payloads[stored.id] else { throw ClipboardHistoryError.missingPayload }
        let selected = asPlainText
            ? [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(ClipboardPanelText.plainText(from: representations, fallback: stored.preview).utf8))]
            : representations
        try await CursorPaster.pasteClipboardHistoryItem(selected)
        if ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.updateAfterPaste),
           let index = metadata.firstIndex(where: { $0.id == stored.id }) {
            metadata[index].lastUsedAt = Date()
            metadata[index].useCount += 1
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
        try save()
        return tag
    }

    func renameTag(_ id: UUID, name: String) throws {
        try ensureLoaded()
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try save()
    }

    func recolorTag(_ id: UUID, colorHex: String) throws {
        try ensureLoaded()
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
        tags[index].colorHex = colorHex
        try save()
    }

    func deleteTag(_ id: UUID) throws {
        try ensureLoaded()
        tags.removeAll { $0.id == id }
        for index in metadata.indices { metadata[index].tagIDs?.removeAll { $0 == id } }
        try save()
    }

    func attachTag(_ tagID: UUID, to itemID: UUID) throws {
        try ensureLoaded()
        guard tags.contains(where: { $0.id == tagID }), let index = metadata.firstIndex(where: { $0.id == itemID }) else { return }
        var tagIDs = metadata[index].tagIDs ?? []
        if !tagIDs.contains(tagID) { tagIDs.append(tagID) }
        metadata[index].tagIDs = tagIDs
        try save()
    }

    func detachTag(_ tagID: UUID, from itemID: UUID) throws {
        try ensureLoaded()
        guard let index = metadata.firstIndex(where: { $0.id == itemID }) else { return }
        metadata[index].tagIDs?.removeAll { $0 == tagID }
        try save()
    }

    func search(tagID: UUID, limit: Int = 100) throws -> [ClipboardItem] {
        try ensureLoaded()
        return metadata.filter { $0.tagIDs?.contains(tagID) == true }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(max(0, limit)).map { makeItem($0) }
    }

    func sorted(_ order: ClipboardHistorySort, ascending: Bool = false, limit: Int = 100) throws -> [ClipboardItem] {
        try ensureLoaded()
        let rows = metadata.sorted { left, right in
            let result: ComparisonResult
            switch order {
            case .lastCopy: result = (left.lastCopiedAt ?? left.lastUsedAt).compare(right.lastCopiedAt ?? right.lastUsedAt)
            case .firstCopy, .copySequence: result = left.createdAt.compare(right.createdAt)
            case .copyCount: result = left.useCount == right.useCount ? .orderedSame : (left.useCount < right.useCount ? .orderedAscending : .orderedDescending)
            case .size:
                let lhs = payloads[left.id]?.reduce(0) { $0 + $1.data.count } ?? 0
                let rhs = payloads[right.id]?.reduce(0) { $0 + $1.data.count } ?? 0
                result = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
            }
            if result == .orderedSame {
                return ascending ? left.id.uuidString < right.id.uuidString : left.id.uuidString > right.id.uuidString
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return Array(rows.prefix(max(0, limit))).map { makeItem($0) }
    }

    func cleanupExpired(now: Date = Date()) throws {
        try ensureLoaded()
        let keepFavorites = ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepFavoritesOnClear, defaultValue: true)
        let keepTagged = ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepTaggedOnClear, defaultValue: true)
        let expired = metadata.filter { row in
            guard !row.isPinned,
                  !(keepFavorites && row.isFavorite),
                  !(keepTagged && !(row.tagIDs ?? []).isEmpty) else { return false }
            let period = ClipboardHistoryEngineSettings.retentionPeriod(for: row.kind)
            guard let days = period.dayCount else { return period == .never }
            return (row.lastCopiedAt ?? row.lastUsedAt) < now.addingTimeInterval(-Double(days) * 86_400)
        }.map(\.id)
        removeItems(expired)
        try save()
    }

    func shouldCapture(_ kind: ClipboardItemKind) -> Bool {
        ClipboardHistoryEngineSettings.shouldCapture(kind)
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
        metadata[index].contentHash = replacement.contentHash
        metadata[index].kind = replacement.kind
        metadata[index].preview = replacement.preview
        payloads[id] = replacement.representations
        payloadOCR.removeValue(forKey: id)
        payloadBarcodes.removeValue(forKey: id)
        dirtyPayloadIDs.insert(id)
        try save()
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
              payloadOCR[id] == nil,
              let data = payloads[id]?.first(where: { ["public.tiff", "public.png", "public.jpeg"].contains($0.type) })?.data else { return }
        indexingImageIDs.insert(id)
        defer { indexingImageIDs.remove(id) }
        let result = await ClipboardImageAnalyzer.analyze(data)
        guard metadata.first(where: { $0.id == id })?.contentHash == row.contentHash else { return }
        payloadOCR[id] = result.recognizedText
        payloadBarcodes[id] = result.barcodePayloads
        dirtyPayloadIDs.insert(id)
        try? save()
    }

    private func removeItems(_ ids: [UUID]) {
        let removed = Set(ids)
        if let pasteSequenceLastID, removed.contains(pasteSequenceLastID) { resetPasteSequence() }
        metadata.removeAll { removed.contains($0.id) }
        for id in removed {
            payloads.removeValue(forKey: id)
            payloadOCR.removeValue(forKey: id)
            payloadBarcodes.removeValue(forKey: id)
            dirtyPayloadIDs.remove(id)
        }
    }

    private func makeItem(_ row: Metadata, representations: [ClipboardRepresentation]? = nil) -> ClipboardItem {
        ClipboardItem(
            id: row.id,
            contentHash: row.contentHash,
            kind: row.kind,
            representations: representations ?? payloads[row.id] ?? [],
            preview: row.preview,
            createdAt: row.createdAt,
            lastCopiedAt: row.lastCopiedAt ?? row.lastUsedAt,
            lastUsedAt: row.lastUsedAt,
            useCount: row.useCount,
            isPinned: row.isPinned,
            isFavorite: row.isFavorite,
            collectionID: row.collectionID,
            title: row.title,
            tagIDs: row.tagIDs ?? [],
            recognizedText: payloadOCR[row.id] ?? "",
            barcodePayloads: payloadBarcodes[row.id] ?? [],
            sourceApp: row.sourceApp
        )
    }

    private func enforceRetention(now: Date) throws {
        let keepFavorites = ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepFavoritesOnClear, defaultValue: true)
        let keepTagged = ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepTaggedOnClear, defaultValue: true)
        let expired = metadata.filter { row in
            guard !row.isPinned,
                  !(keepFavorites && row.isFavorite),
                  !(keepTagged && !(row.tagIDs ?? []).isEmpty) else { return false }
            let period = ClipboardHistoryEngineSettings.retentionPeriod(for: row.kind)
            guard let days = period.dayCount else { return period == .never }
            return (row.lastCopiedAt ?? row.lastUsedAt) < now.addingTimeInterval(-Double(days) * 86_400)
        }.map(\.id)
        removeItems(expired)
        let unpinned = metadata.filter {
            !$0.isPinned
                && !(keepFavorites && $0.isFavorite)
                && !(keepTagged && !($0.tagIDs ?? []).isEmpty)
        }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        let excess = Set(unpinned.dropFirst(ClipboardHistorySettings.retentionCount).map(\.id))
        removeItems(Array(excess))
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let encryptedIndex = try Data(contentsOf: indexURL)
            metadata = try JSONDecoder().decode([Metadata].self, from: encryption.open(encryptedIndex))
            for row in metadata {
                let blob = directoryURL.appendingPathComponent("\(row.id.uuidString).blob.enc")
                let data = try encryption.open(Data(contentsOf: blob))
                let payload = try JSONDecoder().decode(Payload.self, from: data)
                payloads[row.id] = payload.representations
                payloadOCR[row.id] = payload.recognizedText
                payloadBarcodes[row.id] = payload.barcodePayloads
            }
            if FileManager.default.fileExists(atPath: tagsURL.path) {
                tags = try JSONDecoder().decode([ClipboardTag].self, from: encryption.open(Data(contentsOf: tagsURL)))
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
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let activeIDs = Set(metadata.map(\.id))
        for id in dirtyPayloadIDs {
            guard activeIDs.contains(id), let representations = payloads[id] else { continue }
            let payload = try encoder.encode(Payload(
                representations: representations,
                recognizedText: payloadOCR[id],
                barcodePayloads: payloadBarcodes[id]
            ))
            let encrypted = try encryption.seal(payload)
            try encrypted.write(to: directoryURL.appendingPathComponent("\(id.uuidString).blob.enc"), options: .atomic)
        }
        for url in try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasSuffix(".blob.enc") {
            let id = UUID(uuidString: url.lastPathComponent.replacingOccurrences(of: ".blob.enc", with: ""))
            if let id, !activeIDs.contains(id) { try? FileManager.default.removeItem(at: url) }
        }
        try encryption.seal(encoder.encode(metadata)).write(to: indexURL, options: .atomic)
        try encryption.seal(encoder.encode(tags)).write(to: tagsURL, options: .atomic)
        dirtyPayloadIDs.removeAll()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
