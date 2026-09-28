import AppKit
import CryptoKit
import Foundation

/// Local encrypted clipboard history. Every public operation is asynchronous and serialized by the actor.
actor ClipboardHistoryStore {
    private struct Metadata: Codable {
        let id: UUID
        let contentHash: String
        let kind: ClipboardItemKind
        let preview: String
        let createdAt: Date
        var lastUsedAt: Date
        var useCount: Int
        var isPinned: Bool
        var isFavorite: Bool
        var collectionID: UUID?
        var title: String?
        var sourceApp: ClipboardSourceApp
    }

    private struct Payload: Codable {
        let representations: [ClipboardRepresentation]
    }

    private let directoryURL: URL
    private let indexURL: URL
    private let encryption: ClipboardHistoryEncryption
    private var metadata: [Metadata]
    private var payloads: [UUID: [ClipboardRepresentation]]
    private var dirtyPayloadIDs: Set<UUID>
    private var hasLoaded = false

    /// Tests pass a temporary directory and random key. Live installs use a unique Keychain key.
    init(directoryURL: URL = AppStoragePaths.root.appendingPathComponent("ClipboardHistory", isDirectory: true), keyData: Data? = nil) throws {
        self.directoryURL = directoryURL
        indexURL = directoryURL.appendingPathComponent("index.enc")
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
        if let index = metadata.firstIndex(where: { $0.contentHash == item.contentHash }) {
            metadata[index].lastUsedAt = now
            metadata[index].useCount += 1
            metadata[index].sourceApp = item.sourceApp
            payloads[metadata[index].id] = item.representations
            dirtyPayloadIDs.insert(metadata[index].id)
            try enforceRetention(now: now)
            try save()
            return makeItem(metadata[index])
        }

        let row = Metadata(
            id: item.id,
            contentHash: item.contentHash,
            kind: item.kind,
            preview: item.preview,
            createdAt: now,
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
        return makeItem(row)
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
        return metadata.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(max(0, limit)).map(makeItem)
    }

    /// Returns pinned items ordered by last use, newest first.
    func pinned() throws -> [ClipboardItem] {
        try ensureLoaded()
        return metadata.filter(\.isPinned).sorted { $0.lastUsedAt > $1.lastUsedAt }.map(makeItem)
    }

    /// Searches previews, titles, and source app names, with an optional kind filter.
    func search(text: String = "", kind: ClipboardItemKind? = nil, limit: Int = 100) throws -> [ClipboardItem] {
        try ensureLoaded()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return metadata
            .filter { row in
                (kind == nil || row.kind == kind)
                    && (query.isEmpty || [row.preview, row.title ?? "", row.sourceApp.name ?? ""].contains { $0.localizedLowercase.contains(query) })
            }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(max(0, limit))
            .map(makeItem)
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
        metadata.removeAll { $0.id == id }
        payloads.removeValue(forKey: id)
        dirtyPayloadIDs.remove(id)
        try save()
    }

    /// Keeps pinned items unless `includingPinned` is true.
    func clear(includingPinned: Bool = false) throws {
        try ensureLoaded()
        let removed = metadata.filter { includingPinned || !$0.isPinned }.map(\.id)
        metadata.removeAll { includingPinned || !$0.isPinned }
        for id in removed { payloads.removeValue(forKey: id) }
        dirtyPayloadIDs.subtract(removed)
        try save()
    }

    /// Pastes the original representations, or the plain-text preview, through CursorPaster.
    func paste(_ item: ClipboardItem, asPlainText: Bool = false) async throws {
        try ensureLoaded()
        guard let stored = metadata.first(where: { $0.id == item.id }),
              let representations = payloads[stored.id] else { throw ClipboardHistoryError.missingPayload }
        let selected = asPlainText
            ? [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(stored.preview.utf8))]
            : representations
        try await CursorPaster.pasteClipboardHistoryItem(selected)
        if let index = metadata.firstIndex(where: { $0.id == stored.id }) {
            metadata[index].lastUsedAt = Date()
            metadata[index].useCount += 1
            try save()
        }
    }

    private func makeItem(_ row: Metadata) -> ClipboardItem {
        ClipboardItem(
            id: row.id,
            contentHash: row.contentHash,
            kind: row.kind,
            representations: payloads[row.id] ?? [],
            preview: row.preview,
            createdAt: row.createdAt,
            lastUsedAt: row.lastUsedAt,
            useCount: row.useCount,
            isPinned: row.isPinned,
            isFavorite: row.isFavorite,
            collectionID: row.collectionID,
            title: row.title,
            sourceApp: row.sourceApp
        )
    }

    private func enforceRetention(now: Date) throws {
        let cutoff = now.addingTimeInterval(-Double(ClipboardHistorySettings.retentionDays) * 86_400)
        metadata.removeAll { row in
            guard !row.isPinned, row.lastUsedAt < cutoff else { return false }
            payloads.removeValue(forKey: row.id)
            dirtyPayloadIDs.remove(row.id)
            return true
        }
        let unpinned = metadata.filter { !$0.isPinned }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        let excess = Set(unpinned.dropFirst(ClipboardHistorySettings.retentionCount).map(\.id))
        metadata.removeAll { excess.contains($0.id) }
        for id in excess {
            payloads.removeValue(forKey: id)
            dirtyPayloadIDs.remove(id)
        }
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let encryptedIndex = try Data(contentsOf: indexURL)
            metadata = try JSONDecoder().decode([Metadata].self, from: encryption.open(encryptedIndex))
            for row in metadata {
                let blob = directoryURL.appendingPathComponent("\(row.id.uuidString).blob.enc")
                let data = try encryption.open(Data(contentsOf: blob))
                payloads[row.id] = try JSONDecoder().decode(Payload.self, from: data).representations
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
            let payload = try encoder.encode(Payload(representations: representations))
            let encrypted = try encryption.seal(payload)
            try encrypted.write(to: directoryURL.appendingPathComponent("\(id.uuidString).blob.enc"), options: .atomic)
        }
        for url in try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasSuffix(".blob.enc") {
            let id = UUID(uuidString: url.lastPathComponent.replacingOccurrences(of: ".blob.enc", with: ""))
            if let id, !activeIDs.contains(id) { try? FileManager.default.removeItem(at: url) }
        }
        try encryption.seal(encoder.encode(metadata)).write(to: indexURL, options: .atomic)
        dirtyPayloadIDs.removeAll()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
