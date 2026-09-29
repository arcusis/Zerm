import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Zerm

@Suite(.serialized)
struct ClipboardHistoryPanelTests {
    @MainActor
    @Test func filtersSortsSelectsAndMapsQuickPasteSlots() async throws {
        try await withPanelModel { model, store in
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
        try await withPanelModel { model, store in
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
        try await withPanelModel { model, store in
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
        try await withPanelModel { model, store in
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
    @Test func panelLoadsHistoryInPages() async throws {
        try await withPanelModel { model, store in
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
        try await withPanelModel { model, store in
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
        try await withPanelModel { _, store in
            let image = ClipboardItem(
                contentHash: "ocr-search-sample",
                kind: .image,
                representations: [ClipboardRepresentation(type: "public.png", data: Data())],
                preview: "Image",
                recognizedText: "parcel reference 7341",
                barcodePayloads: ["QR-7341"],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            )
            let searchModel = ClipboardHistoryPanelModel(store: store, initialItems: [image])
            searchModel.query = "7341"
            #expect(searchModel.visibleItems.map(\.id) == [image.id])
        }
    }

    @MainActor
    @Test func transformCommandCreatesExpectedClipboardItem() async throws {
        try await withPanelModel { model, store in
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
        try await withPanelModel { _, store in
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
            let model = ClipboardHistoryPanelModel(store: store, initialItems: items)
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
        try await withPanelModel { model, store in
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
            let output = directory.appendingPathComponent("378-a2-panel.png")
            try png.write(to: output)
            print("Clipboard history panel render: \(output.path)")
            window.close()
        }
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
        _ body: @MainActor (ClipboardHistoryPanelModel, ClipboardHistoryStore) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipboard-panel-tests-\(UUID().uuidString)", isDirectory: true)
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 7, count: 32))
        let model = await MainActor.run { ClipboardHistoryPanelModel(store: store) }
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(model, store)
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
        let bitmap = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        return ClipboardRepresentation(type: "public.png", data: data)
    }
}
