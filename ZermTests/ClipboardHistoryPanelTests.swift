import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import Testing

@testable import Zerm

enum ClipboardHistoryRenderAppearance: String, CaseIterable {
    case aqua
    case darkAqua
    case accessibilityHighContrastAqua
    case accessibilityHighContrastDarkAqua

    var colorScheme: ColorScheme { self == .darkAqua || self == .accessibilityHighContrastDarkAqua ? .dark : .light }
}

@MainActor
enum ClipboardHistoryRenderSupport {
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXCell", "AXCheckBox", "AXComboBox", "AXDisclosureTriangle", "AXIncrementor",
        "AXLink", "AXMenuButton", "AXPopUpButton", "AXRadioButton", "AXRow", "AXSearchField",
        "AXSlider", "AXStepper", "AXSwitch", "AXTabGroup", "AXTable", "AXTextArea", "AXTextField",
    ]

    static func render<V: View>(
        _ view: V,
        name: String,
        size: NSSize,
        appearance: ClipboardHistoryRenderAppearance,
        locale: Locale,
        in directory: URL
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rightToLeft = Locale.Language(identifier: locale.identifier).characterDirection == .rightToLeft
        let root = view
            .environment(\.locale, locale)
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.colorScheme, appearance.colorScheme)
            .frame(width: size.width, height: size.height)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -3_200, y: -2_200), size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: NSAppearance.Name(rawValue: appearance.rawValue))
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()

        let deadline = Date().addingTimeInterval(5)
        var previousImage: Data?
        var stableFrames = 0
        while Date() < deadline {
            window.displayIfNeeded()
            guard let content = window.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                try await Task.sleep(for: .milliseconds(40))
                continue
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let image = bitmap.representation(using: .png, properties: [:]) else {
                try await Task.sleep(for: .milliseconds(40))
                continue
            }
            if image == previousImage { stableFrames += 1 } else { stableFrames = 0 }
            if stableFrames >= 2 {
                try image.write(to: directory.appendingPathComponent(name))
                window.close()
                return
            }
            previousImage = image
            try await Task.sleep(for: .milliseconds(40))
        }
        window.close()
        throw ClipboardHistoryRenderError.unstableFrame(name)
    }

    static func renderMatrix<V: View>(
        _ view: V,
        screen: String,
        size: NSSize,
        in directory: URL
    ) async throws {
        for appearance in ClipboardHistoryRenderAppearance.allCases {
            for localeIdentifier in ["en", "he"] {
                let locale = Locale(identifier: localeIdentifier)
                let name = "\(screen)-\(appearance.rawValue)-\(localeIdentifier).png"
                try await render(view, name: name, size: size, appearance: appearance, locale: locale, in: directory)
            }
        }
    }

    static func unlabeledInteractiveElements(in root: NSView) -> [String] {
        accessibilityElements(in: root).filter { interactiveRoles.contains($0.role) && $0.label.isEmpty }.map(\.role)
    }

    static func interactiveElementCount(in root: NSView) -> Int {
        accessibilityElements(in: root).filter { interactiveRoles.contains($0.role) }.count
    }

    private static func accessibilityElements(in root: NSView) -> [(role: String, label: String)] {
        guard let window = root.window else { return [] }
        let application = AXUIElementCreateApplication(getpid())
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowValue) == .success,
              let windows = windowValue as? [AXUIElement] else { return [] }
        let title = window.title
        guard let windowElement = windows.first(where: { element in
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success
                && (value as? String) == title
        }) else { return [] }

        var visited = Set<CFHashCode>()
        var elements: [(role: String, label: String)] = []
        func visit(_ element: AXUIElement) -> [String] {
            guard visited.insert(CFHash(element)).inserted else { return [] }

            var roleValue: CFTypeRef?
            var labelValue: CFTypeRef?
            var descriptionValue: CFTypeRef?
            var subroleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success {
                _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &labelValue)
                _ = AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descriptionValue)
                _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
            }
            var childrenValue: CFTypeRef?
            var childLabels: [String] = []
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
               let children = childrenValue as? [AXUIElement] {
                for child in children { childLabels.append(contentsOf: visit(child)) }
            }
            if childLabels.isEmpty {
                var visibleChildrenValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXVisibleChildren" as CFString, &visibleChildrenValue) == .success,
                   let children = visibleChildrenValue as? [AXUIElement] {
                    for child in children { childLabels.append(contentsOf: visit(child)) }
                }
            }
            if childLabels.isEmpty, roleValue as? String == "AXCell" {
                var titleElementValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXTitleUIElement" as CFString, &titleElementValue) == .success,
                   let titleElementValue {
                    let titleElement = titleElementValue as! AXUIElement
                    childLabels.append(contentsOf: visit(titleElement))
                }
            }
            guard let role = roleValue as? String else { return childLabels }
            let label = [labelValue as? String, descriptionValue as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? ""
            let isWindowChrome = (subroleValue as? String).map {
                ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains($0)
            } ?? false
            let effectiveLabel = label.isEmpty && ["AXRow", "AXCell"].contains(role)
                ? childLabels.joined(separator: ", ")
                : label
            if !isWindowChrome { elements.append((role, effectiveLabel)) }
            return effectiveLabel.isEmpty ? childLabels : [effectiveLabel]
        }
        _ = visit(windowElement)
        return elements
    }
}

enum ClipboardHistoryRenderError: Error {
    case unstableFrame(String)
}

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
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                await model.loadItems()
                if model.items.contains(where: { $0.preview == "MIXED CASE" }) { break }
                try await Task.sleep(for: .milliseconds(25))
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
            let directory = URL(fileURLWithPath: "/tmp/zerm-work", isDirectory: true)
            let output = directory.appendingPathComponent("389-panel-before.png")
            try await ClipboardHistoryRenderSupport.render(
                ClipboardHistoryPanelView(model: renderModel),
                name: output.lastPathComponent,
                size: NSSize(width: 1_050, height: 620),
                appearance: .aqua,
                locale: Locale(identifier: "en"),
                in: directory
            )
            print("Clipboard history panel render: \(output.path)")
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
    @Test func rendersPanelAppearanceAndLocaleMatrix() async throws {
        try await withPanelModel { _, store, _ in
            let directory = URL(fileURLWithPath: "/tmp/zerm-work/404-shots/after/panel", isDirectory: true)
            let source = ClipboardSourceApp(bundleIdentifier: "com.apple.finder", name: "Finder")
            let textItem = panelItem(.plainText, "Release checklist", [text("Release checklist")], source: source)
            let imageItem = panelItem(.image, "Clipboard image", [try pngRepresentation()], source: source)
            let service = LinkPreviewService(fetcher: PanelPreviewFetcher(), cache: nil)
            var states: [(String, ClipboardHistoryPanelModel)] = []

            let selected = ClipboardHistoryPanelModel(store: store, initialItems: [textItem, imageItem])
            selected.select(imageItem)
            selected.isDetailsVisible = true
            selected.isShowingQuickPasteBadges = true
            states.append(("selection-preview-details", selected))

            let empty = ClipboardHistoryPanelModel(store: store)
            await empty.loadItems()
            states.append(("empty", empty))

            let noMatches = ClipboardHistoryPanelModel(store: store, initialItems: [textItem])
            noMatches.query = "kind:url no-match"
            states.append(("no-matches", noMatches))

            let tagID = UUID()
            let taggedItem = panelItem(.plainText, "Tagged note", [text("Tagged note")], source: source, tagIDs: [tagID])
            let tagged = ClipboardHistoryPanelModel(
                store: store,
                initialItems: [taggedItem],
                initialTags: [ClipboardTag(id: tagID, name: "Research", colorHex: "#4268AD")]
            )
            tagged.query = "tag:Research"
            tagged.select(taggedItem)
            states.append(("active-tag-filter", tagged))

            let multiple = ClipboardHistoryPanelModel(store: store, initialItems: [textItem, imageItem])
            multiple.select(textItem)
            multiple.select(imageItem, toggling: true)
            states.append(("multiple-selection", multiple))

            for (name, model) in states {
                try await ClipboardHistoryRenderSupport.renderMatrix(
                    ClipboardHistoryPanelView(model: model, linkService: service),
                    screen: "panel-\(name)",
                    size: NSSize(width: 1_040, height: 650),
                    in: directory
                )
            }
        }
    }

    @MainActor
    @Test func panelAndLibraryInteractiveElementsHaveAccessibilityLabels() async throws {
        try await withPanelModel { _, store, _ in
            let source = ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            let item = try #require(ClipboardItem.capture(
                representations: [text("Accessible clipboard sample")],
                sourceApp: source
            ))
            _ = try await store.capture(item)

            let panelModel = ClipboardHistoryPanelModel(store: store, initialItems: [item])
            panelModel.select(item)
            panelModel.isShowingQuickPasteBadges = true
            let panelView = ClipboardHistoryPanelView(model: panelModel, linkService: LinkPreviewService(fetcher: PanelPreviewFetcher(), cache: nil))
            let panelWindow = NSWindow(contentRect: NSRect(x: -3_200, y: -2_200, width: 1_040, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            panelWindow.isReleasedWhenClosed = false
            panelWindow.title = "Clipboard History Accessibility Audit Panel"
            panelWindow.contentView = NSHostingView(rootView: panelView)
            panelWindow.contentView?.layoutSubtreeIfNeeded()
            panelWindow.makeKeyAndOrderFront(nil)
            panelWindow.displayIfNeeded()
            let panelRoot = try #require(panelWindow.contentView)
            #expect(ClipboardHistoryRenderSupport.interactiveElementCount(in: panelRoot) > 0)
            let panelMissing = ClipboardHistoryRenderSupport.unlabeledInteractiveElements(in: panelRoot)
            #expect(panelMissing.isEmpty, "Panel unlabeled elements: \(panelMissing)")
            panelWindow.close()

            let libraryModel = ClipboardLibraryModel(store: store)
            await libraryModel.start()
            await libraryModel.loadTags()
            libraryModel.selectedIDs = [item.id]
            await libraryModel.select(item.id)
            let libraryWindow = NSWindow(contentRect: NSRect(x: -3_200, y: -2_200, width: 1_120, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            libraryWindow.isReleasedWhenClosed = false
            libraryWindow.title = "Clipboard History Accessibility Audit Library"
            libraryWindow.contentView = NSHostingView(rootView: ClipboardLibraryView(model: libraryModel))
            libraryWindow.contentView?.layoutSubtreeIfNeeded()
            libraryWindow.makeKeyAndOrderFront(nil)
            libraryWindow.displayIfNeeded()
            let libraryRoot = try #require(libraryWindow.contentView)
            #expect(ClipboardHistoryRenderSupport.interactiveElementCount(in: libraryRoot) > 0)
            let libraryMissing = ClipboardHistoryRenderSupport.unlabeledInteractiveElements(in: libraryRoot)
            #expect(libraryMissing.isEmpty, "Library unlabeled elements: \(libraryMissing)")
            libraryWindow.close()
            libraryModel.stop()
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
        try await ClipboardHistoryRenderSupport.render(
            ClipboardHistoryPanelView(model: model, linkService: service),
            name: "\(name).png",
            size: NSSize(width: 1_040, height: 650),
            appearance: .aqua,
            locale: locale,
            in: directory
        )
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
