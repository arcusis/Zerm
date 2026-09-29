import AppKit
import Foundation
import Testing
import KeyboardShortcuts
import SwiftUI
@testable import Zerm

private struct VersionOneArchiveIndex: Codable {
    let formatVersion: Int
    let createdAt: Date
    let entries: [ClipboardHistoryArchive.Entry]
}

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
            let defaults = context.0
            defaults.set(1, forKey: ClipboardHistorySettings.Keys.retentionCount)
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
            let (defaults, directory, key) = context
            let payload = UUID().uuidString
            let item = try #require(ClipboardItem.capture(
                representations: [Self.text(payload)], sourceApp: Self.source
            ))
            _ = try await store.capture(item)
            try await store.flushPendingWrites()
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "enc" {
                let diskData = try Data(contentsOf: file)
                #expect(String(data: diskData, encoding: .utf8)?.contains(payload) != true)
            }
            let reloaded = try ClipboardHistoryStore(directoryURL: directory, keyData: key, defaults: defaults)
            let reloadedItems = try await reloaded.recent()
            let found = reloadedItems.first
            let loaded = try await reloaded.itemWithPayload(try #require(found).id)
            #expect(loaded.representations.first?.data == Data(payload.utf8))
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

    @Test func clipboardHistorySettingsDefaultsAreRegistered() throws {
        let defaults = UserDefaults.standard
        let suite = "ClipboardHistorySettingsDefaultsTests.\(UUID().uuidString)"
        let isolatedDefaults = try #require(UserDefaults(suiteName: suite))
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        let keys = [
            ClipboardHistorySettings.Keys.enabled, ClipboardHistorySettings.Keys.windowPosition,
            ClipboardHistorySettings.Keys.pasteOnClick, ClipboardHistorySettings.Keys.doubleClickPaste,
            ClipboardHistorySettings.Keys.showBadges, ClipboardHistorySettings.Keys.updateAfterPaste,
            ClipboardHistorySettings.Keys.favoritesOnTop, ClipboardHistorySettings.Keys.warnBeforeClear,
            ClipboardHistorySettings.Keys.clearOnQuit, ClipboardHistorySettings.Keys.clearOnRestart,
            ClipboardHistorySettings.Keys.clearOnLock, ClipboardHistorySettings.Keys.clearOnSleep,
            ClipboardHistorySettings.Keys.clearDaily, ClipboardHistorySettings.Keys.clearDailyTime,
            ClipboardHistorySettings.Keys.linkPreviewsEnabled,
            ClipboardHistorySettings.Keys.ignoreConfidential, ClipboardHistorySettings.Keys.ignoreTransient,
            ClipboardHistorySettings.Keys.sort, ClipboardHistorySettings.Keys.copyMergeEnabled,
            ClipboardHistorySettings.Keys.copyMergeSeparator, ClipboardHistorySettings.Keys.copyMergeUpdatesClipboard,
            ClipboardHistorySettings.Keys.saveDictations, ClipboardHistorySettings.Keys.paused,
            ClipboardHistorySettings.Keys.copySound, ClipboardHistorySettings.Keys.pasteSound,
            ClipboardHistorySettings.Keys.deleteSound, ClipboardHistorySettings.Keys.selectionSound
        ]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for key in keys { if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        for key in keys { defaults.removeObject(forKey: key) }
        AppDefaults.registerDefaults()
        #expect(ClipboardHistorySettings.isEnabled)
        #expect(ClipboardHistorySettings.windowPosition == "lastLocation")
        #expect(ClipboardHistorySettings.retentionCount(in: isolatedDefaults) == 500)
        #expect(ClipboardHistorySettings.maximumItemSize(in: isolatedDefaults) == 50 * 1_024 * 1_024)
        #expect(ClipboardHistorySettings.maximumStorageSize(in: isolatedDefaults) == 1_073_741_824)
        #expect(ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.linkPreviewsEnabled, defaultValue: true))
        #expect(ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepFavoritesOnClear, in: isolatedDefaults, defaultValue: true))
        #expect(ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepTaggedOnClear, in: isolatedDefaults, defaultValue: true))
        #expect(ClipboardHistoryEngineSettings.retentionPeriod(for: .plainText, defaults: isolatedDefaults) == .days(90))
        #expect(ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.ignoreConfidential))
        #expect(!ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.clearOnQuit))
        #expect(!ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.copySound))
    }

    @Test func archiveRoundTripPreservesItemAndFavoriteOrder() throws {
        let item = try #require(ClipboardItem.capture(
            representations: [Self.text("archive payload")], sourceApp: Self.source
        ))
        let tag = ClipboardTag(name: "Research", colorHex: "#123456")
        let entry = ClipboardHistoryArchive.Entry(item: ClipboardItem(
            id: item.id, contentHash: item.contentHash, kind: item.kind,
            representations: item.representations, preview: item.preview,
            createdAt: item.createdAt, lastUsedAt: item.lastUsedAt, useCount: 4,
            isPinned: true, isFavorite: true, collectionID: nil, title: "Saved title",
            tagIDs: [tag.id], tagDefinitions: [tag], sourceApp: item.sourceApp
        ), favoriteOrder: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zermclip")
        defer { try? FileManager.default.removeItem(at: url) }
        let passphrase = UUID().uuidString
        try ClipboardHistoryArchive.write([entry], to: url, password: passphrase)
        let imported = try ClipboardHistoryArchive.read(from: url, password: passphrase)
        #expect(imported.count == 1)
        #expect(imported[0].item.representations == item.representations)
        #expect(imported[0].item.title == "Saved title")
        #expect(imported[0].item.isFavorite && imported[0].item.isPinned)
        #expect(imported[0].item.tagIDs == [tag.id])
        #expect(imported[0].item.tagDefinitions == [tag])
        #expect(imported[0].favoriteOrder == 2)
    }

    @Test func archiveImportMergesTagDefinitionsByNameAndRestoresAssignments() async throws {
        try await Self.withStore { store, _ in
            let localTag = try await store.createTag(name: "work", colorHex: "#abcdef")
            let archivedTag = ClipboardTag(name: "Work", colorHex: "#123456")
            let otherTag = ClipboardTag(name: "Later", colorHex: "#654321")
            let item = try #require(ClipboardItem.capture(
                representations: [Self.text("tagged archive payload")], sourceApp: Self.source
            ))
            let archivedItem = ClipboardItem(
                id: item.id, contentHash: item.contentHash, kind: item.kind,
                representations: item.representations, preview: item.preview,
                tagIDs: [archivedTag.id, otherTag.id], tagDefinitions: [archivedTag, otherTag],
                sourceApp: item.sourceApp
            )
            try await store.mergeArchiveEntries([.init(item: archivedItem, favoriteOrder: nil)])
            let tags = try await store.allTags()
            let imported = try #require(try await store.recent().first)
            #expect(tags.count == 2)
            #expect(tags.first(where: { $0.id == localTag.id })?.colorHex == "#abcdef")
            #expect(imported.tagIDs.contains(localTag.id))
            #expect(imported.tagIDs.contains(otherTag.id))
            let fullExportItem = try await store.itemWithPayload(imported.id)
            #expect(fullExportItem.tagDefinitions?.count == 2)
        }
    }

    @Test func cachedSortOrdersTrackCapturesEditsAndDeletes() async throws {
        try await Self.withStore { store, _ in
            let start = Date()
            let first = try #require(ClipboardItem.capture(
                representations: [Self.text("a")], sourceApp: Self.source, createdAt: start
            ))
            let second = try #require(ClipboardItem.capture(
                representations: [Self.text("bb")], sourceApp: Self.source, createdAt: start.addingTimeInterval(1)
            ))
            let third = try #require(ClipboardItem.capture(
                representations: [Self.text("ccc")], sourceApp: Self.source, createdAt: start.addingTimeInterval(2)
            ))
            _ = try await store.capture(first, now: start)
            _ = try await store.capture(second, now: start.addingTimeInterval(1))
            _ = try await store.capture(third, now: start.addingTimeInterval(2))
            _ = try await store.capture(first, now: start.addingTimeInterval(3))

            #expect(try await store.sorted(.lastCopy).map(\.id).first == first.id)
            #expect(try await store.sorted(.firstCopy, ascending: true).map(\.id) == [first.id, second.id, third.id])
            #expect(try await store.sorted(.copyCount).map(\.id).first == first.id)
            #expect(try await store.sorted(.size, ascending: true).map(\.id) == [first.id, second.id, third.id])

            _ = try await store.edit(second.id, representations: [Self.text("bbbbbb")])
            let afterEdit = try await store.sorted(.size, ascending: true).map(\.id)
            #expect(afterEdit == [first.id, third.id, second.id])
            try await store.delete(third.id)
            let afterDelete = try await store.sortedPage(.size, offset: 0, limit: 10).map(\.id)
            #expect(afterDelete == [second.id, first.id])
        }
    }

    @Test func archiveReadsVersionOneWithoutTags() throws {
        let item = try #require(ClipboardItem.capture(
            representations: [Self.text("legacy archive payload")], sourceApp: Self.source
        ))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveDirectory = root.appendingPathComponent("archive", isDirectory: true)
        let itemsDirectory = archiveDirectory.appendingPathComponent("items", isDirectory: true)
        try FileManager.default.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(item.representations).write(to: itemsDirectory.appendingPathComponent("\(item.id.uuidString).json"))
        let index = VersionOneArchiveIndex(
            formatVersion: 1,
            createdAt: Date(),
            entries: [.init(item: ClipboardItem(
                id: item.id, contentHash: item.contentHash, kind: item.kind,
                representations: [], preview: item.preview, createdAt: item.createdAt,
                lastUsedAt: item.lastUsedAt, sourceApp: item.sourceApp
            ), favoriteOrder: nil)]
        )
        try encoder.encode(index).write(to: archiveDirectory.appendingPathComponent("index.json"))
        let zipURL = root.appendingPathComponent("legacy.zermclip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", archiveDirectory.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let imported = try ClipboardHistoryArchive.read(from: zipURL)
        #expect(imported.count == 1)
        #expect(imported[0].item.representations == item.representations)
        #expect(imported[0].item.tagIDs.isEmpty)
        #expect(imported[0].item.tagDefinitions?.isEmpty == true)
    }

    @Test func archiveMergeDeduplicatesByContentHashAndCombinesOrganization() async throws {
        try await Self.withStore { store, _ in
            let original = try #require(ClipboardItem.capture(
                representations: [Self.text("same bytes")], sourceApp: Self.source
            ))
            let existing = try await store.capture(original)
            let archived = ClipboardItem(
                id: UUID(), contentHash: original.contentHash, kind: original.kind,
                representations: original.representations, preview: original.preview,
                createdAt: original.createdAt, lastUsedAt: original.lastUsedAt,
                useCount: 3, isPinned: true, isFavorite: true, collectionID: UUID(),
                title: "Imported title", sourceApp: original.sourceApp
            )
            try await store.mergeArchiveEntries([.init(item: archived, favoriteOrder: 0)])
            let items = try await store.recent()
            #expect(items.count == 1)
            #expect(items[0].id == existing.id)
            #expect(items[0].isPinned && items[0].isFavorite)
            #expect(items[0].title == "Imported title")
        }
    }

    @Test func restartDetectionAndMenuRecentItemsAreBounded() throws {
        #expect(!ClipboardHistoryRuntime.didSystemRestart(previousBootTime: nil, currentBootTime: 100))
        #expect(!ClipboardHistoryRuntime.didSystemRestart(previousBootTime: 100, currentBootTime: 101))
        #expect(ClipboardHistoryRuntime.didSystemRestart(previousBootTime: 100, currentBootTime: 110))
        let items = try (0..<7).map { index in
            try #require(ClipboardItem.capture(
                representations: [Self.text("item \(index)")], sourceApp: Self.source,
                createdAt: Date(timeIntervalSince1970: Double(index))
            ))
        }
        #expect(ClipboardHistoryRuntime.menuRecentItems(from: items).count == 5)
        #expect(ClipboardHistoryRuntime.menuRecentItems(from: items).map(\.preview) == items.prefix(5).map(\.preview))
    }

    @Test @MainActor func pasteNextForwardingSelectsEngineCandidateWithoutKeystrokes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Self.randomKey())
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(ClipboardItem.capture(representations: [Self.text("first")], sourceApp: Self.source, createdAt: Date(timeIntervalSince1970: 1)))
        let second = try #require(ClipboardItem.capture(representations: [Self.text("second")], sourceApp: Self.source, createdAt: Date(timeIntervalSince1970: 2)))
        let savedFirst = try await store.capture(first, now: first.createdAt)
        _ = try await store.capture(second, now: second.createdAt)
        let runtime = ClipboardHistoryRuntime(store: store, monitor: nil)
        let recorder = PasteRecorder()

        let selected = await runtime.pasteNextClipboardItem(formatted: false) { item, plainText in
            await recorder.record(item.id, plainText: plainText)
        }

        #expect(selected?.id == savedFirst.id)
        #expect(await recorder.selection?.0 == savedFirst.id)
        #expect(await recorder.selection?.1 == true)
    }

    @Test @MainActor func runtimeInstallsOnlyOneCleanupTimer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Self.randomKey())
        let runtime = ClipboardHistoryRuntime(store: store, monitor: nil)
        defer {
            runtime.cleanupTimer?.invalidate()
            try? FileManager.default.removeItem(at: directory)
        }

        runtime.startCleanupTimer()
        let firstTimer = runtime.cleanupTimer
        runtime.startCleanupTimer()

        #expect(firstTimer != nil)
        #expect(firstTimer?.isValid == true)
        #expect(runtime.cleanupTimer === firstTimer)
    }

    @Test @MainActor func lockAndSleepNotificationsClearHistoryUsingInjectedCenter() async throws {
        let suite = "ClipboardHistoryLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let keys = [
            ClipboardHistorySettings.Keys.clearOnLock,
            ClipboardHistorySettings.Keys.clearOnSleep,
            ClipboardHistorySettings.Keys.clearOnRestart,
            ClipboardHistorySettings.Keys.clearOnQuit,
            ClipboardHistorySettings.Keys.keepFavoritesOnClear,
            ClipboardHistorySettings.Keys.keepTaggedOnClear
        ]
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(true, forKey: ClipboardHistorySettings.Keys.clearOnLock)
        defaults.set(true, forKey: ClipboardHistorySettings.Keys.clearOnSleep)
        defaults.set(true, forKey: ClipboardHistorySettings.Keys.clearOnRestart)
        defaults.set(true, forKey: ClipboardHistorySettings.Keys.clearOnQuit)
        defaults.set(false, forKey: ClipboardHistorySettings.Keys.keepFavoritesOnClear)
        defaults.set(false, forKey: ClipboardHistorySettings.Keys.keepTaggedOnClear)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Self.randomKey(), defaults: defaults)
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try #require(ClipboardItem.capture(representations: [Self.text("locked item")], sourceApp: Self.source))
        _ = try await store.capture(item)
        let lockNotifications = NotificationCenter()
        let workspaceNotifications = NotificationCenter()
        let runtime = ClipboardHistoryRuntime(
            store: store,
            monitor: nil,
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_000) },
            notificationCenter: NotificationCenter(),
            lockNotificationCenter: lockNotifications,
            workspaceNotificationCenter: workspaceNotifications
        )
        runtime.installLifecycleHooks()

        lockNotifications.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        try await Self.waitUntilEmpty(store)
        #expect(try await store.recent().isEmpty)

        let sleepItem = try #require(ClipboardItem.capture(representations: [Self.text("sleep item")], sourceApp: Self.source))
        _ = try await store.capture(sleepItem)
        workspaceNotifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try await Self.waitUntilEmpty(store)
        #expect(try await store.recent().isEmpty)

        let restartItem = try #require(ClipboardItem.capture(representations: [Self.text("restart item")], sourceApp: Self.source))
        _ = try await store.capture(restartItem)
        #expect(await runtime.clearAfterRestartIfNeeded(previousBootTime: 100, currentBootTime: 110))
        #expect(try await store.recent().isEmpty)

        let quitItem = try #require(ClipboardItem.capture(representations: [Self.text("quit item")], sourceApp: Self.source))
        _ = try await store.capture(quitItem)
        let appNotifications = NotificationCenter()
        let quitRuntime = ClipboardHistoryRuntime(
            store: store,
            monitor: nil,
            defaults: defaults,
            notificationCenter: appNotifications,
            workspaceNotificationCenter: NotificationCenter()
        )
        quitRuntime.installLifecycleHooks()
        appNotifications.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(try await store.recent().isEmpty)
    }

    @Test @MainActor func dailyCleanupUsesInjectedClockAndDefaults() async throws {
        let suite = "ClipboardHistoryDailyCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: ClipboardHistorySettings.Keys.clearDaily)
        defaults.set(9 * 3_600, forKey: ClipboardHistorySettings.Keys.clearDailyTime)
        defaults.set(false, forKey: ClipboardHistorySettings.Keys.keepFavoritesOnClear)
        defaults.set(false, forKey: ClipboardHistorySettings.Keys.keepTaggedOnClear)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Self.randomKey(), defaults: defaults)
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10, minute: 0))!
        let item = try #require(ClipboardItem.capture(representations: [Self.text("daily item")], sourceApp: Self.source))
        _ = try await store.capture(item, now: now)
        let runtime = ClipboardHistoryRuntime(store: store, monitor: nil, defaults: defaults, now: { now })

        await runtime.runScheduledCleanup()

        #expect(try await store.recent().isEmpty)
        #expect(defaults.object(forKey: ClipboardHistorySettings.Keys.lastDailyClear) as? Date == now)
    }

    @Test(.enabled(if: RenderSnapshots.isEnabled)) @MainActor func rendersClipboardPanelStatesForReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Self.randomKey())
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputDirectory = URL(fileURLWithPath: "/tmp/zerm-work/391-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let now = Date()
        let source = Self.source
        let imageData = try #require(Self.textImage("Clipboard image sample"))
        let kinds: [(ClipboardItemKind, ClipboardRepresentation, String)] = [
            (.plainText, Self.text("Plain text sample"), "Plain text sample"),
            (.richText, .init(type: "public.rtf", data: Data("{\\rtf1\\b Rich text sample}".utf8)), "Rich text sample"),
            (.image, .init(type: "public.png", data: imageData), "Image sample"),
            (.fileURLs, .init(type: "public.file-url", data: Data("file:///tmp/sample.txt".utf8)), "sample.txt"),
            (.url, .init(type: "public.url", data: Data("https://example.test/preview".utf8)), "https://example.test/preview"),
            (.email, Self.text("reader@example.test"), "reader@example.test"),
            (.color, .init(type: "public.color", data: Data("#3355aa".utf8)), "#3355aa"),
            (.other, .init(type: "com.example.custom", data: Data("Other sample".utf8)), "Other sample")
        ]
        for (kind, representation, name) in kinds {
            let item = ClipboardItem(
                contentHash: "render-\(kind.rawValue)",
                kind: kind,
                representations: [representation],
                preview: name,
                createdAt: now,
                sourceApp: source
            )
            let model = ClipboardHistoryPanelModel(store: store, initialItems: [item])
            model.select(item)
            try await savePanelImage(model, name: "kind-\(kind.rawValue).png", directory: outputDirectory)
        }

        let emptyModel = ClipboardHistoryPanelModel(store: store)
        try await savePanelImage(emptyModel, name: "empty.png", directory: outputDirectory)

        let noMatchModel = ClipboardHistoryPanelModel(store: store, initialItems: [
            ClipboardItem(contentHash: "no-match-source", kind: .plainText, representations: [Self.text("findable")], preview: "findable", sourceApp: source)
        ])
        noMatchModel.query = "no match"
        try await savePanelImage(noMatchModel, name: "no-matches.png", directory: outputDirectory)

        let tagID = UUID()
        let tagged = ClipboardItem(
            contentHash: "tagged-render",
            kind: .plainText,
            representations: [Self.text("Tagged release notes")],
            preview: "Tagged release notes",
            tagIDs: [tagID],
            sourceApp: source
        )
        let taggedModel = ClipboardHistoryPanelModel(
            store: store,
            initialItems: [tagged],
            initialTags: [ClipboardTag(id: tagID, name: "Release", colorHex: "#3355AA")]
        )
        taggedModel.select(tagged)
        taggedModel.isDetailsVisible = true
        try await savePanelImage(taggedModel, name: "tags.png", directory: outputDirectory)

        let longItems = (0..<500).map { index in
            ClipboardItem(
                contentHash: "long-list-\(index)",
                kind: .plainText,
                representations: [Self.text("Clipboard history item \(index + 1)")],
                preview: "Clipboard history item \(index + 1)",
                createdAt: now.addingTimeInterval(-Double(index)),
                sourceApp: source
            )
        }
        let longListModel = ClipboardHistoryPanelModel(store: store, initialItems: longItems)
        longListModel.select(longItems[0])
        try await savePanelImage(longListModel, name: "long-list.png", directory: outputDirectory)
        print("Clipboard History review renders: \(outputDirectory.path)")
    }

    @MainActor
    private func savePanelImage(_ model: ClipboardHistoryPanelModel, name: String, directory: URL) async throws {
        let window = NSWindow(
            contentRect: NSRect(x: -3_200, y: -2_200, width: 980, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ClipboardHistoryPanelView(model: model))
        window.contentView?.frame = NSRect(origin: .zero, size: NSSize(width: 980, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if window.contentView?.window === window, window.contentView?.needsLayout == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let content = try #require(window.contentView)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name))
        window.close()
    }

    @Test func clipboardShortcutNamesAreDeclaredWithExpectedStorageNames() {
        #expect(KeyboardShortcuts.Name.openClipboardHistory == KeyboardShortcuts.Name("openClipboardHistory"))
        #expect(KeyboardShortcuts.Name.pauseClipboardHistory == KeyboardShortcuts.Name("pauseClipboardHistory"))
        #expect(KeyboardShortcuts.Name.pasteNextClipboardItem == KeyboardShortcuts.Name("pasteNextClipboardItem"))
        #expect(KeyboardShortcuts.Name.pasteNextClipboardItemFormatted == KeyboardShortcuts.Name("pasteNextClipboardItemFormatted"))
    }

    /// Polls until the store is empty or 5 s pass; clearing runs asynchronously after the notification.
    private static func waitUntilEmpty(_ store: ClipboardHistoryStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while try await !store.recent().isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let source = ClipboardSourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")

    private static func text(_ text: String) -> ClipboardRepresentation {
        ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
    }

    private static func textImage(_ value: String) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 420,
            pixelsHigh: 180,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 420, height: 180).fill()
        (value as NSString).draw(at: NSPoint(x: 18, y: 75), withAttributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white
        ])
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func randomKey() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }

    private actor PasteRecorder {
        private(set) var selection: (UUID, Bool)?

        func record(_ id: UUID, plainText: Bool) {
            selection = (id, plainText)
        }
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
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: key, defaults: defaults)
        try await body(store, (defaults, directory, key))
    }
}
