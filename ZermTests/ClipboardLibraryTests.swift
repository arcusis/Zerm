import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Zerm

@Suite(.serialized)
struct ClipboardLibraryTests {
    @MainActor
    @Test func tokenAndDateFiltersApplyToPagedHistory() async throws {
        try await withStore { store, feed, _ in
            let now = Date()
            let tagged = try #require(ClipboardItem.capture(
                representations: [text("Release checklist")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor"),
                createdAt: now
            ))
            let other = try #require(ClipboardItem.capture(
                representations: [text("Old release note")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.browser", name: "Test Browser"),
                createdAt: now.addingTimeInterval(-40 * 86_400)
            ))
            _ = try await store.capture(tagged, now: now)
            _ = try await store.capture(other, now: now.addingTimeInterval(-40 * 86_400))
            let tag = try await store.createTag(name: "Release Notes", colorHex: "#4268AD")
            try await store.attachTag(tag.id, to: tagged.id)

            let model = ClipboardLibraryModel(store: store, feed: feed)
            model.query = "kind:plainText app:test.editor tag:Release%20Notes"
            model.dateFilter = .today
            await model.loadTags()
            await model.reload()

            #expect(model.items.map(\.id) == [tagged.id])
            #expect(!model.hasMore)
        }
    }

    @MainActor
    @Test func liveFeedAndBulkTagActionsUpdateItems() async throws {
        try await withStore { store, feed, _ in
            let model = ClipboardLibraryModel(store: store, feed: feed)
            await model.start()
            let tag = try await store.createTag(name: "Work", colorHex: "#577FBC")
            await model.loadTags()
            let item = try #require(ClipboardItem.capture(
                representations: [text("Work item")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            _ = try await store.capture(item)
            await feed.publish(.inserted(storeID: store.feedStoreID, item: item))
            let deadline = Date().addingTimeInterval(5)
            while !model.items.contains(where: { $0.id == item.id }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(model.items.contains(where: { $0.id == item.id }))
            model.selectedIDs = [item.id]
            await model.togglePinned(true)
            await model.toggleFavorite(true)
            await model.setTag(tag, attached: true)

            let saved = try await store.itemWithPayload(item.id)
            #expect(saved.isPinned)
            #expect(saved.isFavorite)
            #expect(saved.tagIDs.contains(tag.id))
            let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-library-selected-\(UUID().uuidString).zip")
            defer { try? FileManager.default.removeItem(at: archiveURL) }
            try await model.exportSelection(to: archiveURL)
            let exported = try await Task.detached { try ClipboardHistoryArchive.read(from: archiveURL) }.value
            #expect(exported.map(\.item.id) == [item.id])
            await model.deleteSelection()
            #expect(try await store.totalCount() == 0)
            model.stop()
        }
    }

    @MainActor
    @Test func tagCanBeCreatedRenamedRecoloredAndDeleted() async throws {
        try await withStore { store, feed, _ in
            let model = ClipboardLibraryModel(store: store, feed: feed)
            await model.createTag(name: "Draft", colorHex: "#527DDB")
            let tag = try #require(model.tags.first)
            let item = try #require(ClipboardItem.capture(
                representations: [text("Tagged draft")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            _ = try await store.capture(item)
            try await store.attachTag(tag.id, to: item.id)
            await model.updateTag(tag, name: "Reviewed", colorHex: "#4E8D6D")
            let updated = try #require((try await store.allTags()).first)
            #expect(updated.name == "Reviewed")
            #expect(updated.colorHex == "#4E8D6D")
            #expect(await model.tagCounts()[updated.id] == 1)
            await model.deleteTag(updated)
            #expect((try await store.itemWithPayload(item.id)).tagIDs.isEmpty)
        }
    }

    @MainActor
    @Test func mergingTagsMovesItemsAndDeletesSourceTag() async throws {
        try await withStore { store, feed, _ in
            let item = try #require(ClipboardItem.capture(
                representations: [text("Tag merge sample")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            _ = try await store.capture(item)
            let source = try await store.createTag(name: "Old")
            let destination = try await store.createTag(name: "Current")
            try await store.attachTag(source.id, to: item.id)

            let model = ClipboardLibraryModel(store: store, feed: feed)
            await model.mergeTag(source, into: destination)

            #expect(try await store.search(tagID: destination.id, limit: 10).map(\.id) == [item.id])
            #expect(!(try await store.allTags()).contains(where: { $0.id == source.id }))
        }
    }

    @MainActor
    @Test(.enabled(if: RenderSnapshots.isEnabled)) func rendersLibraryStatesToPNG() async throws {
        try await withStore { store, feed, defaults in
            let retentionKey = ClipboardHistorySettings.Keys.retentionByKind
            defaults.set(Dictionary(uniqueKeysWithValues: ClipboardItemKind.allCases.map { ($0.rawValue, "unlimited") }), forKey: retentionKey)
            let directory = URL(fileURLWithPath: "/tmp/zerm-work/390-library-shots", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let tag = try await store.createTag(name: "Research", colorHex: "#4268AD")
            let items = try previewItems(tagID: tag.id)
            _ = try await store.captureBatch(items)
            try await store.attachTag(tag.id, to: items[0].id)
            let model = ClipboardLibraryModel(store: store, feed: feed)
            await model.start()
            let linkService = LinkPreviewService(fetcher: ClipboardLibraryFixtureFetcher(), cache: nil)

            for item in items {
                model.selectedIDs = [item.id]
                await model.select(item.id)
                try await render(ClipboardLibraryView(model: model, linkService: linkService), named: "kind-\(item.kind.rawValue).png", in: directory)
            }

            model.selectedIDs.removeAll()
            model.clearDetail()
            try await render(ClipboardLibraryView(model: model, linkService: linkService), named: "tagged-library.png", in: directory)
            try await render(
                ClipboardLibraryView(model: model, linkService: linkService, layoutDirectionOverride: .rightToLeft)
                    .environment(\.locale, Locale(identifier: "he")),
                named: "history-rtl.png",
                in: directory
            )

            let emptyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-library-empty-\(UUID().uuidString)", isDirectory: true)
            let emptyStore = try ClipboardHistoryStore(directoryURL: emptyDirectory, keyData: Data(repeating: 5, count: 32))
            let emptyModel = ClipboardLibraryModel(store: emptyStore, feed: feed)
            await emptyModel.start()
            try await render(ClipboardLibraryView(model: emptyModel, linkService: linkService), named: "empty.png", in: directory)
            emptyModel.stop()
            try? FileManager.default.removeItem(at: emptyDirectory)

            model.query = "no-results-390"
            await model.reload()
            try await render(ClipboardLibraryView(model: model, linkService: linkService), named: "no-matches.png", in: directory)

            let longItems = (0..<125).compactMap { index in
                ClipboardItem.capture(
                    representations: [text("Clipboard row \(index) — searchable content" )],
                    sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor"),
                    createdAt: Date().addingTimeInterval(-Double(index))
                )
            }
            _ = try await store.captureBatch(longItems)
            let longListModel = ClipboardLibraryModel(store: store, feed: feed)
            await longListModel.start()
            #expect(longListModel.items.count == 100)
            #expect(longListModel.hasMore)
            try await render(ClipboardLibraryView(model: longListModel, linkService: linkService), named: "long-list-first-page.png", in: directory)
            await longListModel.loadMore()
            #expect(longListModel.items.count == 133)
            try await render(ClipboardLibraryView(model: longListModel, linkService: linkService), named: "long-list-loaded-more.png", in: directory)
            longListModel.stop()
        }
    }

    @MainActor
    @Test(.enabled(if: RenderSnapshots.isEnabled)) func rendersLibrarySettingsAndTagScreensAppearanceLocaleMatrix() async throws {
        try await withStore { store, feed, _ in
            let directory = URL(fileURLWithPath: "/tmp/zerm-work/404-shots/after/library", isDirectory: true)
            let tag = try await store.createTag(name: "Research", colorHex: "#4268AD")
            let first = try #require(ClipboardItem.capture(
                representations: [text("Release checklist")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            let second = try #require(ClipboardItem.capture(
                representations: [text("Meeting notes")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.browser", name: "Test Browser")
            ))
            _ = try await store.captureBatch([first, second])
            try await store.attachTag(tag.id, to: first.id)

            let model = ClipboardLibraryModel(store: store, feed: feed)
            await model.start()
            await model.loadTags()
            model.selectedIDs = [first.id]
            await model.select(first.id)
            try await ClipboardHistoryRenderSupport.renderMatrix(
                ClipboardLibraryView(model: model),
                screen: "library-inspector-selection",
                size: NSSize(width: 1_120, height: 720),
                in: directory
            )

            model.selectedIDs.removeAll()
            model.clearDetail()
            try await ClipboardHistoryRenderSupport.renderMatrix(
                ClipboardLibraryView(model: model),
                screen: "library-list",
                size: NSSize(width: 1_120, height: 720),
                in: directory
            )

            model.query = "no-results-404"
            await model.reload()
            try await ClipboardHistoryRenderSupport.renderMatrix(
                ClipboardLibraryView(model: model),
                screen: "library-no-matches",
                size: NSSize(width: 1_120, height: 720),
                in: directory
            )
            model.stop()

            let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-library-empty-404-\(UUID().uuidString)", isDirectory: true)
            let emptyStore = try ClipboardHistoryStore(directoryURL: emptyURL, keyData: Data(repeating: 5, count: 32))
            let emptyModel = ClipboardLibraryModel(store: emptyStore, feed: feed)
            await emptyModel.start()
            try await ClipboardHistoryRenderSupport.renderMatrix(
                ClipboardLibraryView(model: emptyModel),
                screen: "library-empty",
                size: NSSize(width: 1_120, height: 720),
                in: directory
            )
            emptyModel.stop()
            try? FileManager.default.removeItem(at: emptyURL)

            try await ClipboardHistoryRenderSupport.renderMatrix(
                ClipboardTagsView(store: store, onOpenHistory: { _ in }),
                screen: "tags-manager",
                size: NSSize(width: 1_120, height: 720),
                in: directory
            )
            try await ClipboardHistoryRenderSupport.renderMatrix(
                ClipboardHistorySettingsView(),
                screen: "clipboard-settings",
                size: NSSize(width: 1_120, height: 820),
                in: directory
            )
        }
    }

    @MainActor
    @Test(.enabled(if: RenderSnapshots.isEnabled)) func rendersTagManagerToPNG() async throws {
        try await withStore { store, _, _ in
            let directory = URL(fileURLWithPath: "/tmp/zerm-work/390-library-shots", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let first = try await store.createTag(name: "Research", colorHex: "#4268AD")
            _ = try await store.createTag(name: "Recipes", colorHex: "#4E8D6D")
            let item = try #require(ClipboardItem.capture(
                representations: [text("A saved item")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            _ = try await store.capture(item)
            try await store.attachTag(first.id, to: item.id)
            let model = ClipboardLibraryModel(store: store)
            await model.loadTags()
            try await render(ClipboardTagsView(store: store, onOpenHistory: { _ in }), named: "tags-manager.png", in: directory)
            try await render(
                ClipboardTagsView(store: store, onOpenHistory: { _ in }, layoutDirectionOverride: .rightToLeft)
                    .environment(\.locale, Locale(identifier: "he")),
                named: "tags-manager-rtl.png",
                in: directory
            )
        }
    }

    private func withStore(
        _ operation: @MainActor (ClipboardHistoryStore, ClipboardHistoryFeed, UserDefaults) async throws -> Void
    ) async throws {
        let suite = "ClipboardLibraryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 8, count: 32), defaults: defaults)
        let feed = await MainActor.run { ClipboardHistoryFeed() }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try await operation(store, feed, defaults)
    }

    private func previewItems(tagID: UUID) throws -> [ClipboardItem] {
        let source = ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
        let imageData = try pngRepresentation()
        return [
            ClipboardItem(contentHash: "preview-text", kind: .plainText, representations: [text("A plain clipboard note" )], preview: "A plain clipboard note", tagIDs: [tagID], sourceApp: source),
            ClipboardItem(contentHash: "preview-rich", kind: .richText, representations: [ClipboardRepresentation(type: "public.rtf", data: Data("Rich clipboard text".utf8))], preview: "Rich clipboard text", sourceApp: source),
            ClipboardItem(contentHash: "preview-image", kind: .image, representations: [imageData], thumbnailData: imageData.data, preview: "Image sample", sourceApp: source),
            ClipboardItem(contentHash: "preview-file", kind: .fileURLs, representations: [ClipboardRepresentation(type: "public.file-url", data: URL(fileURLWithPath: "/tmp/zerm-work/sample.txt").dataRepresentation)], preview: "sample.txt", sourceApp: source),
            ClipboardItem(contentHash: "preview-link", kind: .url, representations: [ClipboardRepresentation(type: "public.url", data: Data("https://example.test/library".utf8))], preview: "https://example.test/library", sourceApp: source),
            ClipboardItem(contentHash: "preview-email", kind: .email, representations: [text("person@example.test")], preview: "person@example.test", sourceApp: source),
            ClipboardItem(contentHash: "preview-color", kind: .color, representations: [text("#4268AD")], preview: "#4268AD", sourceApp: source),
            ClipboardItem(contentHash: "preview-other", kind: .other, representations: [], preview: "Unclassified clipboard data", sourceApp: source),
        ]
    }

    @MainActor
    private func render<V: View>(_ view: V, named name: String, in directory: URL) async throws {
        try await ClipboardHistoryRenderSupport.render(
            view,
            name: name,
            size: NSSize(width: 1_120, height: 720),
            appearance: .aqua,
            locale: Locale(identifier: "en"),
            in: directory
        )
    }

    private func text(_ value: String) -> ClipboardRepresentation {
        ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))
    }

    private func pngRepresentation() throws -> ClipboardRepresentation {
        let image = NSImage(size: NSSize(width: 80, height: 48))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 80, height: 48)).fill()
        image.unlockFocus()
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return ClipboardRepresentation(type: "public.png", data: try #require(bitmap.representation(using: .png, properties: [:])))
    }
}

private actor ClipboardLibraryFixtureFetcher: ClipboardLinkMetadataFetching {
    func fetch(_ url: URL, kind: ClipboardPreviewLinkKind) async throws -> ClipboardLinkMetadata { ClipboardLinkMetadata() }
}
