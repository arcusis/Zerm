import AppKit
import Quartz
import SwiftUI

@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardHistoryPanelController()

    private(set) var panel: ClipboardHistoryPanel?
    private var model: ClipboardHistoryPanelModel?
    private var previousApplication: NSRunningApplication?
    private var previousWindowFrame: NSRect?
    private var localMonitor: Any?
    private var localFlagsMonitor: Any?
    private var quickLookData: Data?
    private var quickLookURL: URL?
    private var quickLookTemporaryURL: URL?
    private var quickLookExtension = "png"
    private var globalMonitor: Any?
    private var isShowingQuickLook = false

    var targetApplicationName: String? { previousApplication?.localizedName }

    private override init() { super.init() }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let store = ClipboardHistoryRuntime.shared.store else { return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        previousWindowFrame = NSApp.keyWindow?.frame

        let model = ClipboardHistoryPanelModel(store: store)
        model.onCommand = { [weak self] id in self?.executeRegisteredCommand(id) }
        self.model = model
        let panel = ClipboardHistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 444))
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ClipboardHistoryPanelView(model: model, controller: self, tracksSystemClipboard: true))
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        model.reload()
    }

    func close() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
        model = nil
    }

    func paste(_ item: ClipboardItem, asPlainText: Bool = false, pasteSelection: Bool = true) {
        let selection = pasteSelection ? (model?.selection ?? []) : []
        let selected = selection.isEmpty ? [item] : selection
        let joinedSelection = selected.count > 1
        let target = previousApplication
        let store = ClipboardHistoryRuntime.shared.store
        if model?.isPinned != true { panel?.orderOut(nil) }
        guard let store else {
            close()
            return
        }
        Task { @MainActor in
            if let target, !target.isTerminated {
                target.activate(options: [])
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if joinedSelection {
                let text = selected.map { ClipboardPanelText.plainText(from: $0.representations, fallback: $0.preview) }
                    .joined(separator: "\n")
                try? await CursorPaster.pasteClipboardHistoryItem([
                    ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
                ])
            } else {
                try? await store.paste(item, asPlainText: asPlainText)
            }
            closeIfUnpinned()
        }
    }

    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let groups = Dictionary(grouping: item.representations, by: \.itemIndex)
        let objects = groups.keys.sorted().map { index -> NSPasteboardItem in
            let object = NSPasteboardItem()
            for representation in groups[index] ?? [] {
                object.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            object.setData(Data(), forType: ClipboardManager.historyIgnoreType)
            return object
        }
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
    }

    func perform(command id: String) {
        guard let model, let command = model.registry.command(withID: id, for: model.selection) else { return }
        command.perform(model.selection)
    }

    private func executeRegisteredCommand(_ id: String) {
        switch id {
        case "paste": if let item = model?.selectedItem { paste(item) }
        case "copy": if let item = model?.selectedItem { copy(item) }
        case "delete": Task { await model?.deleteSelection() }
        case "showInHistory": if let item = model?.selectedItem { model?.showInHistory(item) }
        case "pasteNext": Task { await ClipboardHistoryRuntime.shared.pasteNextClipboardItem(formatted: false) }
        case "resetPasteSequence": Task { await ClipboardHistoryRuntime.shared.store?.resetPasteSequence() }
        default: break
        }
    }

    func showQuickLook(for item: ClipboardItem) {
        let imageRepresentation = item.representations.first(where: {
            ["public.tiff", "public.png", "public.jpeg", "public.gif", "public.bmp"].contains($0.type)
        })
        quickLookData = imageRepresentation?.data
        switch imageRepresentation?.type {
        case "public.tiff": quickLookExtension = "tiff"
        case "public.jpeg": quickLookExtension = "jpg"
        case "public.gif": quickLookExtension = "gif"
        case "public.bmp": quickLookExtension = "bmp"
        default: quickLookExtension = "png"
        }
        quickLookURL = fileURL(from: item)
        guard quickLookData != nil || quickLookURL != nil,
            let quickLook = QLPreviewPanel.shared()
        else { return }
        isShowingQuickLook = true
        quickLook.dataSource = self
        quickLook.delegate = self
        quickLook.reloadData()
        quickLook.makeKeyAndOrderFront(nil)
    }

    func closeIfUnpinned() {
        if model?.isPinned != true { close() }
    }

    private func position(_ panel: ClipboardHistoryPanel) {
        let point = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first(where: { $0.frame.contains(point) })
        let activeScreen =
            previousWindowFrame.flatMap { frame in NSScreen.screens.first(where: { $0.frame.intersects(frame) }) }
            ?? NSScreen.main
            ?? pointerScreen
        let option = ClipboardHistorySettings.panelPosition
        guard !NSScreen.screens.isEmpty else { return }
        let fallbackScreen = NSScreen.main ?? pointerScreen ?? NSScreen.screens[0]
        let screen: NSScreen
        if option == .pointer {
            screen = pointerScreen ?? activeScreen ?? fallbackScreen
        } else {
            screen = activeScreen ?? fallbackScreen
        }
        let savedKey = "clipboardHistoryPanelFrame.\(displayID(for: screen))"
        var frame = NSRect(origin: .zero, size: panel.frame.size)
        switch option {
        case .lastLocation:
            if let saved = UserDefaults.standard.string(forKey: savedKey) {
                var savedFrame = NSRectFromString(saved)
                // Frames saved by older layouts can be smaller than the current minimum.
                savedFrame.size.width = max(savedFrame.width, ClipboardHistoryPanel.minimumContentSize.width)
                savedFrame.size.height = max(savedFrame.height, ClipboardHistoryPanel.minimumContentSize.height)
                if screen.visibleFrame.intersects(savedFrame) {
                    frame = savedFrame
                } else {
                    frame.origin = centeredOrigin(in: screen.visibleFrame, size: frame.size)
                }
            } else {
                frame.origin = centeredOrigin(in: screen.visibleFrame, size: frame.size)
            }
        case .centerScreen:
            frame.origin = centeredOrigin(in: screen.visibleFrame, size: frame.size)
        case .pointer:
            frame.origin = NSPoint(x: point.x + 10, y: point.y - frame.height - 10)
        }
        frame = clamp(frame, to: screen.visibleFrame)
        panel.setFrame(frame, display: false)
    }

    private func centeredOrigin(in rect: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
    }

    private func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        var result = frame
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    private func displayID(for screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
            ?? screen.localizedName
    }

    private func saveFrame(_ panel: NSPanel) {
        guard let screen = panel.screen else { return }
        let key = "clipboardHistoryPanelFrame.\(displayID(for: screen))"
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: key)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let command = modifiers.contains(.command)
            let option = modifiers.contains(.option)
            let searchHasFocus = self.panel?.firstResponder is NSTextView

            if event.keyCode == 48, !modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control) {
                self.panel?.selectNextKeyView(nil)
                return nil
            }

            if event.keyCode == 53 {
                if !model.query.isEmpty {
                    model.query = ""
                    return nil
                }
                if model.isCommandPaletteVisible {
                    model.isCommandPaletteVisible = false
                    return nil
                }
                self.close()
                return nil
            }
            if command, event.charactersIgnoringModifiers?.lowercased() == "w" {
                self.close()
                return nil
            }
            if command, event.charactersIgnoringModifiers?.lowercased() == "k" {
                model.isCommandPaletteVisible.toggle()
                return nil
            }
            if command, event.charactersIgnoringModifiers?.lowercased() == "c", let item = model.selectedItem {
                self.copy(item)
                return nil
            }
            if command, event.charactersIgnoringModifiers == "⌫" || (command && event.keyCode == 51) {
                Task { await model.deleteSelection() }
                return nil
            }
            if (event.keyCode == 36 || event.keyCode == 76), let item = model.selectedItem,
                !modifiers.contains(.control), !modifiers.contains(.shift), !modifiers.contains(.function)
            {
                if command || !model.isTextEditorVisible {
                    self.paste(item, asPlainText: option)
                    return nil
                }
            }
            if command, event.charactersIgnoringModifiers?.lowercased() == "y", let item = model.selectedItem,
                item.supportsQuickLook
            {
                self.showQuickLook(for: item)
                return nil
            }
            if !searchHasFocus, event.keyCode == 49, let item = model.selectedItem, item.supportsQuickLook {
                self.showQuickLook(for: item)
                return nil
            }
            let quickPasteNumbers: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
            if command, let number = quickPasteNumbers[event.keyCode],
                let item = model.quickPasteItem(forCommandNumber: number)
            {
                self.paste(item, pasteSelection: false)
                return nil
            }
            if command && !model.isShowingQuickPasteBadges { model.isShowingQuickPasteBadges = true }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.model?.isShowingQuickPasteBadges = event.modifierFlags.contains(.command) }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor in self?.model?.isShowingQuickPasteBadges = event.modifierFlags.contains(.command) }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        localFlagsMonitor = nil
    }

    private func fileURL(from item: ClipboardItem) -> URL? {
        guard let data = item.representations.first(where: { $0.type == "public.file-url" })?.data else { return nil }
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        saveFrame(panel)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        saveFrame(panel)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isShowingQuickLook { closeIfUnpinned() }
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        panel = nil
        model = nil
    }
}

extension ClipboardItem {
    fileprivate var supportsQuickLook: Bool { kind == .image || kind == .fileURLs }
}

extension ClipboardHistoryPanelController: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil && quickLookData == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        if let quickLookURL { return quickLookURL as NSURL }
        guard let quickLookData else { return nil }
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipboard-preview-\(UUID().uuidString).\(quickLookExtension)")
        quickLookTemporaryURL = imageURL
        try? quickLookData.write(to: imageURL)
        return imageURL as NSURL
    }

    func previewPanelDidClose(_ panel: QLPreviewPanel!) {
        isShowingQuickLook = false
        if let quickLookTemporaryURL { try? FileManager.default.removeItem(at: quickLookTemporaryURL) }
        quickLookTemporaryURL = nil
    }
}

final class ClipboardHistoryPanel: NSPanel {
    static let minimumContentSize = NSSize(width: 740, height: 420)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // Borderless: a titled window keeps a hidden title-bar strip that clips the top of the content.
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        minSize = Self.minimumContentSize
    }
}
