import AppKit
import Foundation
import Testing
@testable import Zerm

@Suite(.serialized)
struct ClipboardHistoryTests {
    @Test func excludedTypesAndPasswordManagersAreRejected() {
        for marker in ClipboardExclusionPolicy.excludedPasteboardTypes {
            #expect(ClipboardExclusionPolicy.excludes(
                types: [marker], sourceBundleIdentifier: "com.apple.TextEdit", excludedApps: Set(ClipboardHistorySettings.defaultExcludedApps)
            ))
        }
        for bundleID in ClipboardHistorySettings.defaultExcludedApps {
            #expect(ClipboardExclusionPolicy.excludes(
                types: [NSPasteboard.PasteboardType.string.rawValue], sourceBundleIdentifier: bundleID, excludedApps: Set(ClipboardHistorySettings.defaultExcludedApps)
            ))
        }
        #expect(!ClipboardExclusionPolicy.excludes(
            types: [NSPasteboard.PasteboardType.string.rawValue], sourceBundleIdentifier: "com.apple.TextEdit", excludedApps: Set()
        ))
    }

    @Test func zermWritesAreRejectedEvenWithoutPasteboardTransientTypes() {
        #expect(ClipboardExclusionPolicy.excludes(
            types: [NSPasteboard.PasteboardType.string.rawValue, ClipboardManager.historyIgnoreType.rawValue],
            sourceBundleIdentifier: "com.arcusis.zerm",
            excludedApps: []
        ))
        #expect(ClipboardExclusionPolicy.excludes(
            types: [ClipboardManager.pasteSessionType.rawValue], sourceBundleIdentifier: nil, excludedApps: []
        ))
        let pasteboard = NSPasteboard(name: .init("com.arcusis.zerm.tests.\(UUID().uuidString)"))
        #expect(ClipboardManager.setClipboard("dictation", on: pasteboard))
        #expect(ClipboardExclusionPolicy.excludes(
            types: pasteboard.pasteboardItems?.flatMap { $0.types.map(\.rawValue) } ?? [],
            sourceBundleIdentifier: nil,
            excludedApps: []
        ))
    }

    @Test func deduplicationMovesExistingItemToFrontAndUpdatesCount() async throws {
        try await Self.withStore { store, _ in
            let start = Date()
            let first = try #require(ClipboardItem.capture(
                representations: [Self.text("alpha")], sourceApp: Self.source, createdAt: start
            ))
            let second = try #require(ClipboardItem.capture(
                representations: [Self.text("beta")], sourceApp: Self.source, createdAt: start.addingTimeInterval(1)
            ))
            _ = try await store.capture(first, now: start)
            _ = try await store.capture(second, now: start.addingTimeInterval(1))
            _ = try await store.capture(first, now: start.addingTimeInterval(2))
            let recent = try await store.recent()
            #expect(recent.first?.contentHash == first.contentHash)
            #expect(recent.first?.useCount == 2)
            #expect(recent.first?.lastUsedAt == start.addingTimeInterval(2))
        }
    }

    @Test func countRetentionKeepsPinnedItems() async throws {
        try await Self.withStore { store, context in
            let previous = UserDefaults.standard.object(forKey: ClipboardHistorySettings.Keys.retentionCount)
            UserDefaults.standard.set(1, forKey: ClipboardHistorySettings.Keys.retentionCount)
            defer {
                if let previous { UserDefaults.standard.set(previous, forKey: ClipboardHistorySettings.Keys.retentionCount) }
                else { UserDefaults.standard.removeObject(forKey: ClipboardHistorySettings.Keys.retentionCount) }
            }
            let start = Date()
            let pinnedItem = try #require(ClipboardItem.capture(
                representations: [Self.text("pinned")], sourceApp: Self.source, createdAt: start
            ))
            let savedPinned = try await store.capture(pinnedItem, now: start)
            try await store.pin(savedPinned.id)
            for (index, text) in ["older", "newest"].enumerated() {
                let item = try #require(ClipboardItem.capture(
                    representations: [Self.text(text)], sourceApp: Self.source, createdAt: start.addingTimeInterval(Double(index + 1))
                ))
                _ = try await store.capture(item, now: start.addingTimeInterval(Double(index + 1)))
            }
            let newest = try #require(ClipboardItem.capture(
                representations: [Self.text("newest-two")], sourceApp: Self.source, createdAt: start.addingTimeInterval(4)
            ))
            _ = try await store.capture(newest, now: start.addingTimeInterval(4))
            let rows = try await store.recent()
            #expect(rows.contains(where: { $0.id == savedPinned.id && $0.isPinned }))
            #expect(rows.contains(where: { $0.contentHash == newest.contentHash }))
            #expect(rows.count == 2)
        }
    }

    @Test func encryptedIndexAndPayloadReloadWithoutPlaintextOnDisk() async throws {
        try await Self.withStore { store, context in
            let (_, directory, key) = context
            let item = try #require(ClipboardItem.capture(
                representations: [Self.text("secret clipboard payload")], sourceApp: Self.source
            ))
            _ = try await store.capture(item)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "enc" {
                let diskData = try Data(contentsOf: file)
                #expect(String(data: diskData, encoding: .utf8)?.contains("secret clipboard payload") != true)
            }
            let reloaded = try ClipboardHistoryStore(directoryURL: directory, keyData: key)
            let reloadedItems = try await reloaded.recent()
            let found = reloadedItems.first
            #expect(found?.representations.first?.data == Data("secret clipboard payload".utf8))
        }
    }

    @Test func searchAndKindFilterUsePreviewAndType() async throws {
        try await Self.withStore { store, _ in
            let plain = try #require(ClipboardItem.capture(
                representations: [Self.text("launch checklist")], sourceApp: Self.source
            ))
            let url = try #require(ClipboardItem.capture(
                representations: [ClipboardRepresentation(type: "public.url", data: Data("https://example.com".utf8))], sourceApp: Self.source
            ))
            _ = try await store.capture(plain)
            _ = try await store.capture(url)
            let matchingText = try await store.search(text: "CHECKLIST")
            let matchingKind = try await store.search(kind: .url)
            #expect(matchingText.map(\.contentHash) == [plain.contentHash])
            #expect(matchingKind.map(\.contentHash) == [url.contentHash])
        }
    }

    @Test func pasteboardKindsAreRecognized() {
        #expect(ClipboardItem.detectKind(in: [Self.text("text")]) == .plainText)
        #expect(ClipboardItem.detectKind(in: [.init(type: "public.rtf", data: Data())]) == .richText)
        #expect(ClipboardItem.detectKind(in: [.init(type: "public.png", data: Data())]) == .image)
        #expect(ClipboardItem.detectKind(in: [.init(type: "public.file-url", data: Data())]) == .fileURLs)
        #expect(ClipboardItem.detectKind(in: [.init(type: "public.url", data: Data())]) == .url)
        #expect(ClipboardItem.detectKind(in: [.init(type: "public.color", data: Data())]) == .color)
    }

    private static let source = ClipboardSourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")

    private static func text(_ text: String) -> ClipboardRepresentation {
        ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
    }

    private static func withStore(_ body: (ClipboardHistoryStore, (UserDefaults, URL, Data)) async throws -> Void) async throws {
        let suite = "ClipboardHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: key)
        try await body(store, (defaults, directory, key))
    }
}
