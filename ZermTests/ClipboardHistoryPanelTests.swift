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
        "NoWindowUnderTest", "AXButton", "AXCell", "AXCheckBox", "AXComboBox", "AXDisclosureTriangle", "AXIncrementor",
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

    /// Walks the view's accessibility tree in-process through NSAccessibility. The cross-process AX API
    /// depends on the window server and did not list the test window during full-suite runs.
    private static func accessibilityElements(in root: NSView) -> [(role: String, label: String)] {
        var elements: [(role: String, label: String)] = []
        var visited = Set<ObjectIdentifier>()
        @discardableResult
        func visit(_ element: Any) -> [String] {
            guard let object = element as? NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(object as AnyObject)).inserted else { return [] }
            var childLabels: [String] = []
            for child in object.accessibilityChildren() ?? [] { childLabels.append(contentsOf: visit(child)) }
            guard let role = object.accessibilityRole()?.rawValue else { return childLabels }
            let label = [object.accessibilityLabel(), object.accessibilityTitle()]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? ""
            let subrole = object.accessibilitySubrole()?.rawValue ?? ""
            let isWindowChrome = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(subrole)
            let effectiveLabel = label.isEmpty && ["AXRow", "AXCell"].contains(role) ? childLabels.joined(separator: ", ") : label
            if !isWindowChrome { elements.append((role, effectiveLabel)) }
            return effectiveLabel.isEmpty ? childLabels : [effectiveLabel]
        }
        visit(root)
        return elements.isEmpty ? [("NoWindowUnderTest", "")] : elements
    }
}

enum ClipboardHistoryRenderError: Error {
    case unstableFrame(String)
}

@Suite(.serialized)
struct ClipboardHistoryPanelTests {
    @MainActor
    @Test func emptyFilteredPageKeepsRecoveryAndClearFiltersRestoresHistory() async throws {
        try await withPanelModel { model, store, _ in
            let item = try #require(ClipboardItem.capture(representations: [text("Keep this history item")], sourceApp: .init(bundleIdentifier: "test.editor", name: "Editor")))
            _ = try await store.capture(item)
            await model.loadItems()
            model.query = "no-such-text"
            await model.loadItems()
            #expect(model.items.isEmpty)
            #expect(model.hasActiveFilters)
            model.clearFilters()
            await model.loadItems()
            #expect(!model.hasActiveFilters)
            #expect(model.visibleItems.map(\.id) == [item.id])
            model.railFilter = .favorites
            await model.loadItems()
            #expect(model.visibleItems.isEmpty && model.hasActiveFilters)
            model.clearFilters()
            await model.loadItems()
            #expect(model.visibleItems.map(\.id) == [item.id])
        }
    }

    @MainActor
    @Test func removedItemCannotSilentlyDiscardEditorDraft() async throws {
        try await withPanelModel { model, store, _ in
            let item = try #require(ClipboardItem.capture(representations: [text("Original")], sourceApp: .init(bundleIdentifier: nil, name: nil)))
            _ = try await store.capture(item)
            await model.loadItems()
            await model.beginEditing(item)
            model.textBeingEdited = "Unsaved draft"
            try await store.delete(item.id)
            await model.saveEditedText()
            #expect(model.isTextEditorVisible)
            #expect(model.textBeingEdited == "Unsaved draft")
            #expect(model.editingErrorMessage != nil)
            #expect(model.errorMessage == nil)
            #expect(!model.isSavingEdit)
        }
    }

    @MainActor
    @Test func copyAndEditLoadFullPayloadInsteadOfTruncatedMetadata() async throws {
        try await withPanelModel { model, store, _ in
            let value = String(repeating: "long clipboard text ", count: 60) + "end-marker"
            let item = try #require(ClipboardItem.capture(representations: [text(value)], sourceApp: .init(bundleIdentifier: "test.editor", name: "Editor")))
            _ = try await store.capture(item)
            await model.loadItems()
            let row = try #require(model.items.first)
            #expect(row.representations.isEmpty)
            #expect(row.preview.count == 500)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("existing clipboard", forType: .string)
            await model.copy(row, to: pasteboard)
            #expect(pasteboard.string(forType: .string) == value)
            #expect(pasteboard.types?.contains(ClipboardManager.historyIgnoreType) == true)
            await model.beginEditing(row)
            #expect(model.textBeingEdited == value)
            await model.saveEditedText()
            let saved = try await store.itemWithPayload(row.id)
            #expect(ClipboardPanelText.plainText(from: saved.representations, fallback: saved.preview) == value)
        }
    }

    @MainActor
    @Test func failedCopyPreservesExistingClipboardAndReportsError() async throws {
        try await withPanelModel { model, _, _ in
            let missing = ClipboardItem(contentHash: "missing", kind: .plainText, representations: [], preview: "missing", sourceApp: .init(bundleIdentifier: nil, name: nil))
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("keep this", forType: .string)
            await model.copy(missing, to: pasteboard)
            #expect(pasteboard.string(forType: .string) == "keep this")
            #expect(model.errorMessage != nil)
        }
    }

    @MainActor
    @Test func searchAndAppFiltersFindOlderItemsBeyondFirstPage() async throws {
        try await withPanelModel { model, store, defaults in
            defaults.set(1000, forKey: ClipboardHistorySettings.Keys.retentionCount)
            let now = Date()
            let value = String(repeating: "older document ", count: 60) + "unique-deep-marker"
            let older = try #require(ClipboardItem.capture(representations: [text(value)], sourceApp: .init(bundleIdentifier: "test.old-app", name: "Old App")))
            _ = try await store.capture(older, now: now.addingTimeInterval(-60))
            let newer = (0..<150).map { index in
                ClipboardItem(contentHash: "newer-\(index)", kind: .plainText, representations: [text("recent \(index)")], preview: "recent \(index)", sourceApp: .init(bundleIdentifier: "test.editor", name: "Editor"))
            }
            _ = try await store.captureBatch(newer, now: now)
            await model.loadItems()
            #expect(!model.items.contains(where: { $0.id == older.id }))
            let olderApp = model.sourceApps.first { $0.bundleIdentifier == "test.old-app" }
            #expect(olderApp?.count == 1)
            model.query = "unique-deep-marker"
            await model.loadItems()
            #expect(model.visibleItems.map(\.id) == [older.id])
            model.query = ""
            model.appFilter = "test.old-app"
            await model.loadItems()
            #expect(model.visibleItems.map(\.id) == [older.id])
            model.dateFilter = .today
            model.railFilter = .favorites
            model.clearFilters()
            #expect(model.query.isEmpty && model.appFilter == nil && model.dateFilter == .anytime && model.railFilter == .history)
            await model.loadItems()
            #expect(model.visibleItems.count == 100)
            #expect(model.canLoadMore)
        }
    }

    @MainActor
    @Test func detailAndMultiPastePayloadsPreserveFullContentAndOrder() async throws {
        try await withPanelModel { model, store, _ in
            let first = try #require(ClipboardItem.capture(representations: [text(String(repeating: "first ", count: 150))], sourceApp: .init(bundleIdentifier: nil, name: nil)))
            let second = try #require(ClipboardItem.capture(representations: [text("second")], sourceApp: .init(bundleIdentifier: nil, name: nil)))
            _ = try await store.captureBatch([first, second])
            await model.loadItems()
            let rows = [second, first].compactMap { item in model.items.first(where: { $0.id == item.id }) }
            let loaded = try await model.fullItems(for: rows)
            #expect(loaded.map(\.id) == [second.id, first.id])
            #expect(loaded.last?.representations.first?.data == first.representations.first?.data)
            model.select(try #require(rows.last))
            await eventually { model.detailItem?.id == first.id }
            #expect(model.detailItem?.representations == first.representations)
        }
    }

    @MainActor
    @Test func panelKeyboardMonitorIgnoresEditorsAndOtherWindows() {
        let panel = ClipboardHistoryPanel(contentRect: NSRect(x: -4000, y: -4000, width: 820, height: 444))
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { panel.close(); other.close() }
        #expect(ClipboardHistoryPanelController.shouldHandleKeyEvent(in: panel, panel: panel, isEditing: false))
        #expect(!ClipboardHistoryPanelController.shouldHandleKeyEvent(in: panel, panel: panel, isEditing: true))
        #expect(!ClipboardHistoryPanelController.shouldHandleKeyEvent(in: other, panel: panel, isEditing: false))
        #expect(!ClipboardHistoryPanelController.shouldHandleKeyEvent(in: nil, panel: panel, isEditing: false))
    }

    @MainActor
    @Test func mergeSplitAndCopyMergeKeepTextBeyondPreviewLimit() async throws {
        try await withPanelModel { _, store, _ in
            let longLine = String(repeating: "long line ", count: 100)
            let first = try #require(ClipboardItem.capture(representations: [text(longLine + "\nlast line")], sourceApp: .init(bundleIdentifier: nil, name: nil)))
            let second = try #require(ClipboardItem.capture(representations: [text("second")], sourceApp: .init(bundleIdentifier: nil, name: nil)))
            _ = try await store.captureBatch([first, second])
            let parts = try await store.split(first.id)
            let partPayloads = try await store.itemWithPayload(try #require(parts.first).id)
            #expect(ClipboardPanelText.plainText(from: partPayloads.representations, fallback: partPayloads.preview) == longLine)
            let merged = try #require(try await store.merge([first.id, second.id]))
            let payload = try await store.itemWithPayload(merged.id)
            #expect(ClipboardPanelText.plainText(from: payload.representations, fallback: payload.preview) == longLine + "\nlast line\nsecond")
            let appended = try #require(try await store.appendCopyToPreviousText("tail"))
            let appendedPayload = try await store.itemWithPayload(appended.id)
            #expect(ClipboardPanelText.plainText(from: appendedPayload.representations, fallback: appendedPayload.preview).hasSuffix("\ntail"))
            #expect((appendedPayload.representations.first?.data.count ?? 0) > 1000)
        }
    }

    @MainActor
    @Test func panelWindowHasNoTitleBarStripAboveTheContent() {
        let panel = ClipboardHistoryPanel(contentRect: NSRect(x: -4000, y: -4000, width: 820, height: 444))
        panel.contentView = NSHostingView(rootView: Color.clear)
        #expect(!panel.styleMask.contains(.titled))
        #expect(panel.contentLayoutRect.height == panel.frame.height)
        #expect(panel.contentView?.safeAreaInsets.top == 0)
        #expect(panel.canBecomeKey)
        panel.close()
    }

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
    @Test func codeItemCanFormatJSONAndOpenEditorThroughCommands() async throws {
        try await withPanelModel { model, store, _ in
            let value = "{\"value\":1}"
            let code = ClipboardItem(contentHash: "code-actions", kind: .code, representations: [text(value)], preview: value, sourceApp: .init(bundleIdentifier: "test.editor", name: "Editor"))
            _ = try await store.capture(code)
            await model.loadItems()
            let command = try #require(model.registry.command(withID: "transform.jsonPrettyPrint", for: model.selection))
            command.perform(model.selection)
            await eventually { model.selectedItem?.id != nil && model.selectedItem?.id != code.id }
            let formatted = try #require(model.selectedItem)
            let payload = try await store.itemWithPayload(formatted.id)
            let formattedText = ClipboardPanelText.plainText(from: payload.representations, fallback: payload.preview)
            #expect(formattedText.contains("\n"))
            let object = try #require(JSONSerialization.jsonObject(with: Data(formattedText.utf8)) as? [String: Int])
            #expect(object["value"] == 1)
            let edit = try #require(model.registry.command(withID: "edit", for: model.selection))
            edit.perform(model.selection)
            await eventually { model.isTextEditorVisible }
            #expect(model.textBeingEdited == formattedText)
        }
    }

    @MainActor
    @Test func invalidJSONTransformExplainsFailureAndPreservesOriginal() async throws {
        try await withPanelModel { model, store, _ in
            let value = "{invalid JSON}"
            let code = ClipboardItem(contentHash: "invalid-json-actions", kind: .code, representations: [text(value)], preview: value, sourceApp: .init(bundleIdentifier: "test.editor", name: "Editor"))
            _ = try await store.capture(code)
            await model.loadItems()
            let command = try #require(model.registry.command(withID: "transform.jsonPrettyPrint", for: model.selection))
            command.perform(model.selection)
            await eventually { model.errorMessage != nil }
            #expect(model.errorMessage == String(localized: "This transform cannot be applied to the selected text."))
            #expect(model.selectedIDs == [code.id])
            let original = try await store.itemWithPayload(code.id)
            #expect(ClipboardPanelText.plainText(from: original.representations, fallback: original.preview) == value)
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
    @Test(.enabled(if: RenderSnapshots.isEnabled)) func rendersClipboardPanelOffscreenToPNG() async throws {
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

            let imageRepresentation = try pngRepresentation()
            let image = ClipboardItem(
                contentHash: "render-image",
                kind: .image,
                representations: [imageRepresentation],
                preview: "Image",
                recognizedText: "QR code: release build 4821",
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            )
            let renderModel = ClipboardHistoryPanelModel(
                store: store,
                defaults: defaults,
                initialItems: [image]
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
    @Test func accessibilityLabelsArePresentOnPanelAndLibrary() async throws {
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
            NSApp.activate(ignoringOtherApps: true)
            panelWindow.orderFrontRegardless()
            panelWindow.makeKeyAndOrderFront(nil)
            panelWindow.displayIfNeeded()
            let panelRoot = try #require(panelWindow.contentView)
            let panelMissing = ClipboardHistoryRenderSupport.unlabeledInteractiveElements(in: panelRoot)
            #expect(panelMissing.isEmpty, "Panel unlabeled elements: \(panelMissing)")
            panelWindow.close()

            let libraryModel = ClipboardLibraryModel(store: store)
            await libraryModel.start()
            libraryModel.selectedIDs = [item.id]
            await libraryModel.select(item.id)
            let libraryWindow = NSWindow(contentRect: NSRect(x: -3_200, y: -2_200, width: 1_120, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            libraryWindow.isReleasedWhenClosed = false
            libraryWindow.title = "Clipboard History Accessibility Audit Library"
            libraryWindow.contentView = NSHostingView(rootView: ClipboardLibraryView(model: libraryModel))
            libraryWindow.contentView?.layoutSubtreeIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
            libraryWindow.orderFrontRegardless()
            libraryWindow.makeKeyAndOrderFront(nil)
            libraryWindow.displayIfNeeded()
            let libraryRoot = try #require(libraryWindow.contentView)
            let libraryMissing = ClipboardHistoryRenderSupport.unlabeledInteractiveElements(in: libraryRoot)
            #expect(libraryMissing.isEmpty, "Library unlabeled elements: \(libraryMissing)")
            libraryWindow.close()
            libraryModel.stop()
        }
    }

    /// Every sidebar/preview/details combination must fit the panel's minimum window size; when the
    /// columns' minimums exceed it, SwiftUI overflows and clips both edges of the panel.
    @MainActor
    @Test func everyToggleCombinationFitsTheMinimumPanelSize() async throws {
        try await withPanelModel { _, store, defaults in
            let source = ClipboardSourceApp(bundleIdentifier: "com.apple.finder", name: "Finder")
            let item = panelItem(.plainText, "Release checklist", [text("Release checklist")], source: source)
            let minimum = ClipboardHistoryPanel.minimumContentSize
            for collapsed in [false, true] {
                for preview in [true, false] {
                    for details in [true, false] {
                        let model = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [item])
                        model.select(item)
                        model.isSidebarCollapsed = collapsed
                        model.isPreviewVisible = preview
                        model.isDetailsVisible = details
                        let host = NSHostingController(rootView: ClipboardHistoryPanelView(model: model))
                        let fitting = host.sizeThatFits(in: .zero)
                        #expect(fitting.width <= minimum.width, "collapsed \(collapsed), preview \(preview), details \(details): needs \(fitting.width) pt")
                        #expect(fitting.height <= minimum.height, "collapsed \(collapsed), preview \(preview), details \(details): needs \(fitting.height) pt tall")
                        if RenderSnapshots.isEnabled {
                            try renderToggleState(model, name: "toggle-sidebar\(collapsed ? "Collapsed" : "Open")-preview\(preview)-details\(details)", size: minimum)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func renderToggleState(_ model: ClipboardHistoryPanelModel, name: String, size: NSSize) throws {
        let panel = ClipboardHistoryPanel(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height))
        panel.contentView = NSHostingView(rootView: ClipboardHistoryPanelView(model: model))
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let view = try #require(panel.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: "/tmp/zerm-work/414-shots/toggles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
        panel.close()
    }

    @MainActor
    @Test(.enabled(if: RenderSnapshots.isEnabled)) func rendersEveryPanelStateOffscreenToPNGs() async throws {
        try await withPanelModel { _, store, defaults in
            let directory = URL(fileURLWithPath: "/tmp/zerm-work/414-shots/panel", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = ClipboardSourceApp(bundleIdentifier: "com.apple.finder", name: "Finder")
            let sampleImage = try pngRepresentation()
            let rtf = ClipboardRepresentation(type: "public.rtf", data: Data("{\\rtf1\\ansi Rich clipboard sample}".utf8))
            let samples: [(String, ClipboardItem)] = [
                ("plain-text", panelItem(.plainText, "Release checklist", [text("Release checklist")], source: source)),
                ("rich-text", panelItem(.richText, "Formatted clipboard sample", [rtf], source: source)),
                ("image", panelItem(.image, "Copied image", [sampleImage], source: source)),
                ("file", panelItem(.fileURLs, "release-notes.txt", [fileRepresentation("/tmp/zerm-work/414-shots/release-notes.txt")], source: source)),
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

            let longItems = (0..<240).map { index in
                panelItem(.plainText, "Long history row \(index) with searchable release notes", [text("Long history row \(index) with searchable release notes")], source: source)
            }
            let longModel = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: longItems)
            longModel.select(longItems[118])
            try await savePanelShot("long-list", model: longModel, service: previewService, to: directory)
        }
    }

    @Test func panelRowsUseReferenceSymbols() {
        #expect(ClipboardItemKind.plainText.rowSymbolName == "doc")
        #expect(ClipboardItemKind.richText.rowSymbolName == "doc.richtext")
        #expect(ClipboardItemKind.url.rowSymbolName == "link")
        #expect(ClipboardItemKind.image.rowSymbolName == "photo")
        #expect(ClipboardItemKind.fileURLs.rowSymbolName == "doc.on.doc")
        #expect(ClipboardItemKind.color.rowSymbolName == "paintpalette")
        #expect(ClipboardItemKind.email.rowSymbolName == "envelope")
    }

    @MainActor
    @Test func railFiltersKindsAndFavorites() async throws {
        try await withPanelModel { _, store, defaults in
            let source = ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Test Editor")
            var plainItem = panelItem(.plainText, "Plain note", [text("Plain note")], source: source)
            plainItem.isFavorite = true
            let rich = panelItem(.richText, "Rich note", [text("Rich note", type: "public.rtf")], source: source)
            let image = panelItem(.image, "Neutral image", [try pngRepresentation()], source: source)
            let model = ClipboardHistoryPanelModel(
                store: store,
                defaults: defaults,
                initialItems: [plainItem, rich, image]
            )

            model.railFilter = .text
            #expect(Set(model.visibleItems.map(\.id)) == Set([plainItem.id, rich.id]))
            model.railFilter = .favorites
            #expect(model.visibleItems.map(\.id) == [plainItem.id])
            model.railFilter = .kind(.image)
            #expect(model.visibleItems.map(\.id) == [image.id])
        }
    }

    @MainActor
    @Test(.enabled(if: RenderSnapshots.isEnabled)) func rendersPanelAppearanceAndLocaleMatrix() async throws {
        try await withPanelModel { _, store, defaults in
            let directory = URL(fileURLWithPath: "/tmp/zerm-work/414-shots/panel", isDirectory: true)
            let source = ClipboardSourceApp(bundleIdentifier: "com.apple.finder", name: "Finder")
            let imageData = try pngRepresentation()
            let rtf = ClipboardRepresentation(type: "public.rtf", data: Data("{\\rtf1\\ansi Rich clipboard sample}".utf8))
            let samples: [(String, ClipboardItem)] = [
                ("text", panelItem(.plainText, "Weekly release checklist", [text("Weekly release checklist")], source: source)),
                ("rich-text", panelItem(.richText, "Formatted clipboard sample", [rtf], source: source)),
                ("image", panelItem(.image, "Neutral blue image", [imageData], source: source)),
                ("link", panelItem(.url, "https://example.test/guide", [text("https://example.test/guide", type: "public.url")], source: source)),
                ("file", panelItem(.fileURLs, "release-notes.txt", [fileRepresentation("/tmp/zerm-work/414-shots/release-notes.txt")], source: source)),
                ("color", panelItem(.color, "#336699", [text("#336699")], source: source)),
                ("email", panelItem(.email, "reader@example.test", [text("reader@example.test")], source: source)),
                ("code", panelItem(.code, "func answer() {\n  return 42\n}", [text("func answer() {\n  return 42\n}")], source: source)),
                ("other", panelItem(.other, "Other clipboard data", [], source: source)),
            ]
            let service = LinkPreviewService(fetcher: PanelPreviewFetcher(imageData: imageData.data), cache: nil)
            for (name, item) in samples {
                let model = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [item])
                model.select(item)
                try await ClipboardHistoryRenderSupport.renderMatrix(
                    ClipboardHistoryPanelView(model: model, linkService: service),
                    screen: "panel-\(name)",
                    size: NSSize(width: 820, height: 444),
                    in: directory
                )
            }

            let empty = ClipboardHistoryPanelModel(store: store, defaults: defaults)
            await empty.loadItems()
            let noMatches = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [samples[0].1])
            noMatches.query = "kind:url no-match"
            let longItems = (0..<240).map { index in
                panelItem(.plainText, "History row \(index) with searchable release notes", [text("History row \(index) with searchable release notes")], source: source)
            }
            let longList = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: longItems)
            longList.select(longItems[118])
            let appFiltered = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [samples[0].1, samples[1].1])
            appFiltered.appFilter = "com.apple.finder"
            let commands = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [samples[0].1])
            commands.select(samples[0].1)
            commands.isCommandPaletteVisible = true

            for (name, model) in [("empty", empty), ("no-matches", noMatches), ("sidebar-app-filter", appFiltered), ("long-list", longList), ("commands", commands)] {
                try await ClipboardHistoryRenderSupport.renderMatrix(
                    ClipboardHistoryPanelView(model: model, linkService: service),
                    screen: "panel-\(name)",
                    size: NSSize(width: 820, height: 444),
                    in: directory
                )
            }
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
        source: ClipboardSourceApp
    ) -> ClipboardItem {
        ClipboardItem(
            contentHash: "panel-render-\(UUID().uuidString)",
            kind: kind,
            representations: representations,
            preview: preview,
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
    private let imageData: Data?

    init(imageData: Data? = nil) { self.imageData = imageData }

    func fetch(_ url: URL, kind: ClipboardPreviewLinkKind) async throws -> ClipboardLinkMetadata {
        ClipboardLinkMetadata(title: "Guide preview", siteName: "Example", author: "Sample publisher", imageData: imageData)
    }
}
