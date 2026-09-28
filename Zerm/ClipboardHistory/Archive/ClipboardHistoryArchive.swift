import CommonCrypto
import CryptoKit
import Foundation

enum ClipboardHistoryArchive {
    struct Entry: Codable, Sendable {
        var item: ClipboardItem
        var favoriteOrder: Int?
    }

    private struct Index: Codable {
        let formatVersion: Int
        let createdAt: Date
        let entries: [Entry]
    }

    private struct SealedArchiveEnvelope: Codable {
        let salt: Data
        let sealedArchive: Data
    }

    static func write(_ entries: [Entry], to destination: URL, password: String? = nil) throws {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveDirectory = workingDirectory.appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: archiveDirectory.appendingPathComponent("items", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var indexEntries: [Entry] = []
        for var entry in entries {
            let representations = entry.item.representations
            let blobURL = archiveDirectory.appendingPathComponent("items/\(entry.item.id.uuidString).json")
            try encoder.encode(representations).write(to: blobURL, options: .atomic)
            entry.item = ClipboardItem(
                id: entry.item.id,
                contentHash: entry.item.contentHash,
                kind: entry.item.kind,
                representations: [],
                preview: entry.item.preview,
                createdAt: entry.item.createdAt,
                lastUsedAt: entry.item.lastUsedAt,
                useCount: entry.item.useCount,
                isPinned: entry.item.isPinned,
                isFavorite: entry.item.isFavorite,
                collectionID: entry.item.collectionID,
                title: entry.item.title,
                sourceApp: entry.item.sourceApp
            )
            indexEntries.append(entry)
        }
        try encoder.encode(Index(formatVersion: 1, createdAt: Date(), entries: indexEntries))
            .write(to: archiveDirectory.appendingPathComponent("index.json"), options: .atomic)

        let zipURL = workingDirectory.appendingPathComponent("history.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", archiveDirectory.path, zipURL.path])
        let output: Data
        if let password, !password.isEmpty {
            let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
            let key = try deriveKey(password: password, salt: salt)
            output = try encoder.encode(SealedArchiveEnvelope(salt: salt, sealedArchive: try AES.GCM.seal(Data(contentsOf: zipURL), using: key).combined!))
        } else {
            output = try Data(contentsOf: zipURL)
        }
        try output.write(to: destination, options: .atomic)
    }

    static func read(from source: URL, password: String? = nil) throws -> [Entry] {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        var archiveData = try Data(contentsOf: source)
        if let envelope = try? JSONDecoder().decode(SealedArchiveEnvelope.self, from: archiveData) {
            guard let password, !password.isEmpty else { throw ClipboardHistoryError.invalidArchivePassword }
            archiveData = try AES.GCM.open(.init(combined: envelope.sealedArchive), using: deriveKey(password: password, salt: envelope.salt))
        }
        let zipURL = workingDirectory.appendingPathComponent("history.zip")
        try archiveData.write(to: zipURL)
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, workingDirectory.path])
        let archiveDirectory = workingDirectory.appendingPathComponent("archive", isDirectory: true)
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: archiveDirectory.appendingPathComponent("index.json")))
        guard index.formatVersion == 1 else { throw ClipboardHistoryError.unsupportedArchiveVersion }
        return try index.entries.map { entry in
            let blobURL = archiveDirectory.appendingPathComponent("items/\(entry.item.id.uuidString).json")
            let representations = try JSONDecoder().decode([ClipboardRepresentation].self, from: Data(contentsOf: blobURL))
            let item = ClipboardItem(
                id: entry.item.id,
                contentHash: entry.item.contentHash,
                kind: entry.item.kind,
                representations: representations,
                preview: entry.item.preview,
                createdAt: entry.item.createdAt,
                lastUsedAt: entry.item.lastUsedAt,
                useCount: entry.item.useCount,
                isPinned: entry.item.isPinned,
                isFavorite: entry.item.isFavorite,
                collectionID: entry.item.collectionID,
                title: entry.item.title,
                sourceApp: entry.item.sourceApp
            )
            guard let verified = ClipboardItem.capture(
                representations: representations,
                sourceApp: entry.item.sourceApp,
                createdAt: entry.item.createdAt
            ), verified.contentHash == entry.item.contentHash else {
                throw ClipboardHistoryError.corruptArchive
            }
            return Entry(item: item, favoriteOrder: entry.favoriteOrder)
        }
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var keyData = [UInt8](repeating: 0, count: 32)
        let result = password.withCString { passwordPointer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPointer,
                    password.utf8.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    200_000,
                    &keyData,
                    keyData.count
                )
            }
        }
        guard result == kCCSuccess else { throw ClipboardHistoryError.encryptionFailed }
        return SymmetricKey(data: Data(keyData))
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ClipboardHistoryError.archiveOperationFailed }
    }
}
