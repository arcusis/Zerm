import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Zerm

@Suite(.serialized)
struct ClipboardHistoryPanelTests {
    @MainActor
    @Test func favoritesOnTopUsesInjectedDefaults() async throws {
        try await withPanelModel { _, store, defaults in
            defaults.set(false, forKey: ClipboardHistorySettings.Keys.favoritesOnTop)
            let model = ClipboardHistoryPanelModel(store: store, defaults: defaults)
            #expect(!model.favoritesOnTop)
            model.favoritesOnTop = true
            #expect(defaults.bool(forKey: ClipboardHistorySettings.Keys.favoritesOnTop))
        }
    }

    @MainActor
    @Test func filtersSortsSelectsAndMapsQuickPasteSlots() async throws {
        try await withPanelModel { model, store, defaults in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let alpha = try #require(
                ClipboardItem.capture(
                    representations: [text("alpha item")],
                    sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor"),
                    createdAt: base
                ))
            let beta = try #require(
                ClipboardItem.capture(
                    representations: [text("beta item with considerably more bytes than the link preview")],
                    sourceApp: ClipboardSourceApp(bundleIdentifier: "test.browser", name: "Test Browser"),
                    createdAt: base.addingTimeInterval(10)
                ))
            let link = try #require(
                ClipboardItem.capture(
                    representations: [.init(type: "public.url", data: Data("https://example.test/path".utf8))],
                    sourceApp: ClipboardSourceApp(bundleIdentifier: "test.browser", name: "Test Browser"),
                    createdAt: base.addingTimeInterval(20)
                ))
            _ = try await store.capture(alpha, now: base)
            _ = try await store.capture(beta, now: base.addingTimeInterval(10))
            _ = try await store.capture(link, now: base.addingTimeInterval(20))
            _ = try await store.capture(alpha, now: base.addingTimeInterval(30))
            await model.loadItems()

            #expect(model.visibleItems.map(\.preview).first == "alpha item")
            model.query = "BETA"
            #expect(
                model.visibleItems.map(\.preview) == ["beta item with considerably more bytes than the link preview"])
            model.query = "kind:plainText kind:url app:Test%20Browser"
            #expect(
                model.visibleItems.map(\.preview) == [
                    "https://example.test/path", "beta item with considerably more bytes than the link preview",
                ])

            model.query = ""
            model.favoritesOnTop = false
            model.sort = .size
            await model.loadItems()
            #expect(model.visibleItems.first?.preview == "beta item with considerably more bytes than the link preview")
            model.sort = .firstCopy
            await model.loadItems()
            #expect(model.visibleItems.first?.preview == "alpha item")

            model.sort = .copyCount
            await model.loadItems()
            #expect(model.visibleItems.first?.useCount == 2)
            model.reversed = true
            await model.loadItems()
            #expect(model.visibleItems.last?.useCount == 2)
            model.reversed = false
            try await store.favorite(beta.id)
            model.favoritesOnTop = true
            await model.loadItems()
            model.sort = .lastCopy
            await model.loadItems()
            #expect(model.visibleItems.first?.isFavorite == true)
            model.favoritesOnTop = false
            #expect(model.visibleItems.first?.isFavorite == false)

            model.favoritesOnTop = true
            model.sort = .lastCopy
            let first = try #require(model.visibleItems.first)
            model.select(first)
            model.moveSelection(by: 1, extending: true)
            #expect(model.selectedIDs.count == 2)
            #expect(model.quickPasteItem(forCommandNumber: 1)?.id == model.visibleItems[0].id)
            #expect(model.quickPasteItem(forCommandNumber: 3)?.id == model.visibleItems[2].id)
            #expect(model.quickPasteItem(forCommandNumber: 0) == nil)
            #expect(model.quickPasteItem(forCommandNumber: 9) == nil)
        }
    }

    @MainActor
    @Test func commandRegistryFiltersAndInvokesRegisteredCommands() async throws {
        try await withPanelModel { model, store, defaults in
            let item = try #require(
                ClipboardItem.capture(
                    representations: [text("palette sample")],
                    sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
                ))
            _ = try await store.capture(item)
            await model.loadItems()

            #expect(model.registry.command(withID: "paste", for: []) == nil)
            #expect(model.registry.command(withID: "merge", for: []) == nil)
            var invoked = false
            model.registry.register(
                .init(id: "test.command", title: "Test command", isEnabled: { $0.count == 1 }) { _ in
                    invoked = true
                })
            let selection = [try #require(model.selectedItem)]
            let command = try #require(model.registry.command(withID: "test.command", for: selection))
            command.perform(selection)
            #expect(invoked)
            #expect(model.registry.command(withID: "test.command", for: []) == nil)
        }
    }

    @MainActor
    @Test func commandAvailabilityTracksSelectionAndRegistersEveryTransform() async throws {
        try await withPanelModel { model, store, defaults in
            let first = try #require(ClipboardItem.capture(
                representations: [text("first")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            let second = try #require(ClipboardItem.capture(
                representations: [text("second")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            _ = try await store.capture(first)
            _ = try await store.capture(second)
            await model.loadItems()

            let oneItem = [first]
            let twoItems = [first, second]
            #expect(model.registry.command(withID: "split", for: oneItem) != nil)
            #expect(model.registry.command(withID: "merge", for: oneItem) == nil)
            #expect(model.registry.command(withID: "merge", for: twoItems) != nil)
            #expect(model.registry.command(withID: "transform.uppercase", for: oneItem) != nil)
            #expect(model.registry.command(withID: "transform.uppercase", for: []) == nil)
            #expect(ClipboardTextTransform.allCases.allSatisfy {
                model.registry.command(withID: "transform.\($0.rawValue)", for: oneItem) != nil
            })
        }
    }

    @MainActor
    @Test func feedUpdatesOpenModelAndPropagatesRemovalAndClear() async throws {
        try await withPanelModel { model, store, defaults in
            let first = try #require(ClipboardItem.capture(
                representations: [text("selected item")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            _ = try await store.capture(first)
            await model.loadItems()
            model.select(try #require(model.items.first))

            let second = try #require(ClipboardItem.capture(
                representations: [text("live copy")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            _ = try await store.capture(second)
            await eventually { model.items.first?.id == second.id }
            #expect(model.items.first?.id == second.id)
            #expect(model.selectedIDs == [first.id])

            try await store.delete(second.id)
            await eventually { !model.items.contains { $0.id == second.id } }
            #expect(!model.items.contains { $0.id == second.id })

            try await store.clear(includingPinned: true, keepingFavorites: false, keepingTagged: false)
            await eventually { model.items.isEmpty }
            #expect(model.items.isEmpty)
            #expect(model.visibleItems.isEmpty)
        }
    }

    @MainActor
    @Test func loadMoreAppendsEveryPageAndPreservesSelection() async throws {
        try await withPanelModel { model, store, defaults in
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let items = (0..<205).map { index in
                ClipboardItem(
                    contentHash: "panel-page-\(index)",
                    kind: .plainText,
                    representations: [text("Page item \(index)")],
                    preview: "Page item \(index)",
                    createdAt: now.addingTimeInterval(TimeInterval(index)),
                    sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
                )
            }
            _ = try await store.captureBatch(items, now: now)
            await model.loadItems()
            let firstItem = try #require(model.items.first)
            model.select(firstItem)
            let selectedID = firstItem.id

            while model.canLoadMore { await model.loadMore() }

            #expect(model.items.count == 205)
            #expect(model.selectedIDs == [selectedID])
            #expect(model.canLoadMore == false)
        }
    }

    @MainActor
    @Test func panelLoadsHistoryInPages() async throws {
        try await withPanelModel { model, store, defaults in
            let now = Date()
            let items = (0..<250).map { index in
                ClipboardItem(
                    contentHash: "page-\(index)", kind: .plainText,
                    representations: [text("page row \(index)")], preview: "page row \(index)",
                    createdAt: now.addingTimeInterval(Double(index)),
                    lastUsedAt: now.addingTimeInterval(Double(index)),
                    sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
                )
            }
            _ = try await store.captureBatch(items, now: now)
            try await store.flushPendingWrites()
            await model.loadItems()
            #expect(model.items.count == 100)
            #expect(model.canLoadMore)
            await model.loadMore()
            #expect(model.items.count == 200)
            await model.loadMore()
            #expect(model.items.count == 250)
            #expect(!model.canLoadMore)
        }
    }

    @MainActor
    @Test func tagSearchTokenFiltersMatchingItems() async throws {
        try await withPanelModel { model, store, defaults in
            let tagged = try #require(ClipboardItem.capture(
                representations: [text("release notes")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            let untagged = try #require(ClipboardItem.capture(
                representations: [text("meeting notes")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            _ = try await store.capture(tagged)
            _ = try await store.capture(untagged)
            let tag = try await store.createTag(name: "Release Notes", colorHex: "#446688")
            try await store.attachTag(tag.id, to: tagged.id)
            await model.loadItems()

            model.query = "tag:Release%20Notes"
            #expect(model.visibleItems.map(\.id) == [tagged.id])
        }
    }

    @MainActor
    @Test func imageOCRTextIsSearchableInPanelModel() async throws {
        try await withPanelModel { _, store, defaults in
            let image = ClipboardItem(
                contentHash: "ocr-search-sample",
                kind: .image,
                representations: [ClipboardRepresentation(type: "public.png", data: Data())],
                preview: "Image",
                recognizedText: "parcel reference 7341",
                barcodePayloads: ["QR-7341"],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            )
            let searchModel = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [image])
            searchModel.query = "7341"
            #expect(searchModel.visibleItems.map(\.id) == [image.id])
        }
    }

    @MainActor
    @Test func transformCommandCreatesExpectedClipboardItem() async throws {
        try await withPanelModel { model, store, defaults in
            let item = try #require(ClipboardItem.capture(
                representations: [text("Mixed Case")],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            ))
            _ = try await store.capture(item)
            await model.loadItems()
            model.select(try #require(model.items.first))

            let command = try #require(model.registry.command(withID: "transform.uppercase", for: model.selection))
            command.perform(model.selection)
            for _ in 0..<200 {
                try await Task.sleep(nanoseconds: 25_000_000)
                await model.loadItems()
                if model.items.contains(where: { $0.preview == "MIXED CASE" }) { break }
            }

            #expect(model.items.contains(where: { $0.preview == "MIXED CASE" }))
            #expect(model.items.contains(where: { $0.id == item.id && $0.preview == "Mixed Case" }))
        }
    }

    @MainActor
    @Test func onlyOneOpenShortcutHandlerNameIsRegistered() {
        #expect(ClipboardHistoryRuntime.openShortcutNames == [.openClipboardHistory])
        #expect(ClipboardHistoryRuntime.openShortcutNames.count == 1)
    }

    @Test func panelPositionRoundTripsThroughSettingsKey() {
        let previousValue = UserDefaults.standard.object(forKey: ClipboardHistorySettings.Keys.windowPosition)
        defer {
            if let previousValue { UserDefaults.standard.set(previousValue, forKey: ClipboardHistorySettings.Keys.windowPosition) }
            else { UserDefaults.standard.removeObject(forKey: ClipboardHistorySettings.Keys.windowPosition) }
        }

        ClipboardHistorySettings.panelPosition = .pointer
        #expect(ClipboardHistorySettings.windowPosition == "pointer")
        #expect(ClipboardHistorySettings.panelPosition == .pointer)
    }

    @Test func plainTextUsesFullRepresentationInsteadOfShortPreview() {
        let fullText = String(repeating: "long clipboard value ", count: 40).trimmingCharacters(in: .whitespaces)
        let preview = String(fullText.prefix(500))
        #expect(ClipboardPanelText.plainText(from: [text(fullText)], fallback: preview) == fullText)

        let attributed = NSAttributedString(string: fullText)
        let range = NSRange(location: 0, length: (fullText as NSString).length)
        let rtfData = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        if let rtfData {
            let rtf = ClipboardRepresentation(type: "public.rtf", data: rtfData)
            #expect(ClipboardPanelText.plainText(from: [rtf], fallback: preview) == fullText)
        } else {
            Issue.record("RTF representation failed to build")
        }

        let html = ClipboardRepresentation(
            type: "public.html",
            data: Data("<html><body>\(fullText)</body></html>".utf8)
        )
        #expect(ClipboardPanelText.plainText(from: [html], fallback: preview) == fullText)
    }

    @MainActor
    @Test func lazyPanelHostOpensWithFiveHundredItemsWithinOneSecond() async throws {
        try await withPanelModel { _, store, defaults in
            let now = Date()
            let items = (0..<500).map { index in
                ClipboardItem(
                    contentHash: "sample-\(index)",
                    kind: .plainText,
                    representations: [text("Clipboard sample \(index)")],
                    preview: "Clipboard sample \(index)",
                    createdAt: now.addingTimeInterval(-Double(index)),
                    lastUsedAt: now.addingTimeInterval(-Double(index)),
                    sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
                )
            }
            let model = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: items)
            model.select(items[0])
            let startedAt = ProcessInfo.processInfo.systemUptime
            let panel = ClipboardHistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 570))
            panel.setFrameOrigin(NSPoint(x: -3200, y: -2200))
            panel.contentView = NSHostingView(rootView: ClipboardHistoryPanelView(model: model))
            panel.contentView?.layoutSubtreeIfNeeded()
            let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            print("500-item panel host setup: \(elapsedMilliseconds) ms")
            // About 100 ms on a Mac, several times that on shared CI runners; an eager list of 500 rows takes seconds.
            #expect(elapsedMilliseconds < 1_000, "Panel host setup took \(elapsedMilliseconds) ms")
            panel.close()
        }
    }

    @MainActor
    @Test func rendersClipboardPanelOffscreenToPNG() async throws {
        try await withPanelModel { model, store, defaults in
            let now = Date()
            let samples = [
                ("Weekly release checklist", now.addingTimeInterval(-90)),
                ("https://example.test/design", now.addingTimeInterval(-45)),
                ("Copied notes with a longer preview line for clipping", now.addingTimeInterval(-10)),
            ]
            for (value, timestamp) in samples {
                guard
                    let item = ClipboardItem.capture(
                        representations: [text(value)],
                        sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor"),
                        createdAt: timestamp
                    )
                else {
                    Issue.record("Sample clipboard item failed to build")
                    continue
                }
                _ = try await store.capture(item, now: item.createdAt)
            }
            await model.loadItems()
            model.isDetailsVisible = true

            let tagID = UUID()
            let imageRepresentation = try pngRepresentation()
            let image = ClipboardItem(
                contentHash: "render-image",
                kind: .image,
                representations: [imageRepresentation],
                preview: "Image",
                tagIDs: [tagID],
                recognizedText: "QR code: release build 4821",
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            )
            let taggedItem = ClipboardItem(
                contentHash: "render-tagged",
                kind: .plainText,
                representations: [text("Tagged release checklist")],
                preview: "Tagged release checklist",
                tagIDs: [tagID],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            )
            let renderModel = ClipboardHistoryPanelModel(
                store: store,
                defaults: defaults,
                initialItems: [image, taggedItem],
                initialTags: [ClipboardTag(id: tagID, name: "Release", colorHex: "#3355AA")]
            )
            renderModel.select(image)
            renderModel.isDetailsVisible = true
            let window = NSWindow(
                contentRect: NSRect(x: -3200, y: -2200, width: 1050, height: 620),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ClipboardHistoryPanelView(model: renderModel))
            window.contentView?.frame = NSRect(origin: .zero, size: NSSize(width: 1050, height: 620))
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            window.displayIfNeeded()

            let bounds = window.contentView?.bounds ?? .zero
            let contentView = try #require(window.contentView)
            let bitmap = try #require(contentView.bitmapImageRepForCachingDisplay(in: bounds))
            contentView.cacheDisplay(in: bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: "/tmp/zerm-work", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent("389-panel-before.png")
            try png.write(to: output)
            print("Clipboard history panel render: \(output.path)")
            window.close()
        }
    }

    @MainActor
    @Test func rendersEveryPanelStateOffscreenToPNGs() async throws {
        try await withPanelModel { _, store, defaults in
            let directory = URL(fileURLWithPath: "/tmp/zerm-work/389-shots", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = ClipboardSourceApp(bundleIdentifier: "com.apple.finder", name: "Finder")
            let sampleImage = try pngRepresentation()
            let rtf = ClipboardRepresentation(type: "public.rtf", data: Data("{\\rtf1\\ansi Rich clipboard sample}".utf8))
            let samples: [(String, ClipboardItem)] = [
                ("plain-text", panelItem(.plainText, "Release checklist", [text("Release checklist")], source: source)),
                ("rich-text", panelItem(.richText, "Formatted clipboard sample", [rtf], source: source)),
                ("image", panelItem(.image, "Copied image", [sampleImage], source: source)),
                ("file", panelItem(.fileURLs, "release-notes.txt", [fileRepresentation("/tmp/zerm-work/389-file.txt")], source: source)),
                ("link", panelItem(.url, "https://example.test/guide", [text("https://example.test/guide", type: "public.url")], source: source)),
                ("email", panelItem(.email, "person@example.test", [text("person@example.test")], source: source)),
                ("color", panelItem(.color, "#336699", [text("#336699")], source: source)),
                ("other", panelItem(.other, "Other clipboard data", [], source: source)),
            ]
            let previewService = LinkPreviewService(fetcher: PanelPreviewFetcher(), cache: nil)
            for (name, item) in samples {
                let model = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [item])
                model.select(item)
                model.isDetailsVisible = true
                try await savePanelShot(name, model: model, service: previewService, to: directory)
            }

            let emptyModel = ClipboardHistoryPanelModel(store: store, defaults: defaults)
            await emptyModel.loadItems()
            try await savePanelShot("empty", model: emptyModel, service: previewService, to: directory)

            let noMatchModel = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [samples[0].1])
            noMatchModel.query = "kind:url no-result"
            try await savePanelShot("no-matches", model: noMatchModel, service: previewService, to: directory)

            let tagID = UUID()
            let tagged = panelItem(.plainText, "Tagged clipboard note", [text("Tagged clipboard note")], source: source, tagIDs: [tagID])
            let tagModel = ClipboardHistoryPanelModel(
                store: store,
                defaults: defaults,
                initialItems: [tagged],
                initialTags: [ClipboardTag(id: tagID, name: "Release", colorHex: "#3355AA")]
            )
            tagModel.query = "tag:Release"
            tagModel.select(tagged)
            try await savePanelShot("active-tag-filter", model: tagModel, service: previewService, to: directory)
            try await savePanelShot(
                "active-tag-filter-he",
                model: tagModel,
                service: previewService,
                to: directory,
                locale: Locale(identifier: "he")
            )

            let longItems = (0..<240).map { index in
                panelItem(.plainText, "Long history row \(index) with searchable release notes", [text("Long history row \(index) with searchable release notes")], source: source)
            }
            let longModel = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: longItems)
            longModel.select(longItems[118])
            try await savePanelShot("long-list", model: longModel, service: previewService, to: directory)
        }
    }

    @MainActor
    private func savePanelShot(
        _ name: String,
        model: ClipboardHistoryPanelModel,
        service: LinkPreviewService,
        to directory: URL,
        locale: Locale = .current
    ) async throws {
        let window = NSWindow(
            contentRect: NSRect(x: -3_200, y: -2_200, width: 1_040, height: 650),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ClipboardHistoryPanelView(model: model, linkService: service).environment(\.locale, locale)
        )
        window.contentView?.frame = NSRect(origin: .zero, size: NSSize(width: 1_040, height: 650))
        window.contentView?.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 180_000_000)
        window.displayIfNeeded()
        let content = try #require(window.contentView)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        window.close()
    }

    private func panelItem(
        _ kind: ClipboardItemKind,
        _ preview: String,
        _ representations: [ClipboardRepresentation],
        source: ClipboardSourceApp,
        tagIDs: [UUID] = []
    ) -> ClipboardItem {
        ClipboardItem(
            contentHash: "panel-render-\(UUID().uuidString)",
            kind: kind,
            representations: representations,
            preview: preview,
            tagIDs: tagIDs,
            sourceApp: source
        )
    }

    private func fileRepresentation(_ path: String) -> ClipboardRepresentation {
        ClipboardRepresentation(type: "public.file-url", data: URL(fileURLWithPath: path).dataRepresentation)
    }

    /// Polls until the live feed has delivered, instead of a fixed sleep that is too short on slow CI runners.
    @MainActor
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func withPanelModel(
        _ body: @MainActor (ClipboardHistoryPanelModel, ClipboardHistoryStore, UserDefaults) async throws -> Void
    ) async throws {
        let suite = "ClipboardHistoryPanelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            suite, isDirectory: true)
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 7, count: 32), defaults: defaults)
        let model = await MainActor.run { ClipboardHistoryPanelModel(store: store, defaults: defaults) }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(model, store, defaults)
    }

    private func text(_ value: String, type: String = NSPasteboard.PasteboardType.string.rawValue) -> ClipboardRepresentation {
        ClipboardRepresentation(type: type, data: Data(value.utf8))
    }

    private func pngRepresentation() throws -> ClipboardRepresentation {
        let image = NSImage(size: NSSize(width: 80, height: 48))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 80, height: 48)).fill()
        image.unlockFocus()
        let bitmap = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        return ClipboardRepresentation(type: "public.png", data: data)
    }
}

private actor PanelPreviewFetcher: ClipboardLinkMetadataFetching {
    func fetch(_ url: URL, kind: ClipboardPreviewLinkKind) async throws -> ClipboardLinkMetadata {
        ClipboardLinkMetadata(title: "Guide preview", siteName: "Example", author: "Clipboard History")
    }
}
