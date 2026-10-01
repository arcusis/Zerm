import AppKit
import Quartz
import SwiftUI

@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardHistoryPanelController()

    private(set) var panel: ClipboardHistoryPanel?
    private(set) var model: ClipboardHistoryPanelModel?
    private var previousApplication: NSRunningApplication?
    private var storeFeedStoreID: UUID?
    private let defaults: UserDefaults
    private var localMonitor: Any?
    private var localFlagsMonitor: Any?
    private var quickLookData: Data?
    private var quickLookURL: URL?
    private var quickLookTemporaryURL: URL?
    private var quickLookExtension = "png"
    private var globalMonitor: Any?
    private var isShowingQuickLook = false
    private var isPasting = false

    var targetApplicationName: String? { previousApplication?.localizedName }
    var targetApplicationProcessIdentifier: pid_t? { previousApplication?.processIdentifier }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        let currentStore = ClipboardHistoryRuntime.shared.store
        if let currentStore,
           let storeFeedStoreID,
           currentStore.feedStoreID != storeFeedStoreID
        {
            discardPresentation()
            self.storeFeedStoreID = nil
        }
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let currentStore else { return }
        show(store: currentStore, frontmostApplication: NSWorkspace.shared.frontmostApplication)
    }

    func show(store: ClipboardHistoryStore, frontmostApplication: NSRunningApplication?, present: Bool = true) {
        if storeFeedStoreID != store.feedStoreID {
            discardPresentation()
            storeFeedStoreID = store.feedStoreID
        }
        if panel?.isVisible == true {
            if present { panel?.makeKeyAndOrderFront(nil) }
            return
        }
        previousApplication = frontmostApplication
        if model == nil {
            let newModel = ClipboardHistoryPanelModel(store: store, defaults: defaults)
            newModel.onCommand = { [weak self] id in self?.executeRegisteredCommand(id) }
            model = newModel
        }
        if panel == nil, let model {
            let newPanel = ClipboardHistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 444))
            newPanel.delegate = self
            newPanel.contentView = NSHostingView(rootView: ClipboardHistoryPanelView(model: model, controller: self, tracksSystemClipboard: present).defaultAppStorage(defaults))
            panel = newPanel
        }
        guard let panel, let model else { return }
        model.isCommandPaletteVisible = false
        model.commandQuery = ""
        model.commandSelectionID = nil
        model.presentationID += 1
        if present {
            position(panel)
            panel.makeKeyAndOrderFront(nil)
            installKeyMonitor()
        }
        model.reload(preservingLoadedPage: true)
    }

    func close() {
        removeKeyMonitor()
        closeQuickLookIfNeeded()
        model?.isCommandPaletteVisible = false
        model?.commandQuery = ""
        model?.commandSelectionID = nil
        panel?.orderOut(nil)
    }

    private func discardPresentation() {
        removeKeyMonitor()
        closeQuickLookIfNeeded()
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    private func disposePanel() {
        discardPresentation()
        storeFeedStoreID = nil
    }

    private func closeQuickLookIfNeeded() {
        guard isShowingQuickLook, let quickLook = QLPreviewPanel.shared() else { return }
        quickLook.close()
        isShowingQuickLook = false
        quickLook.dataSource = nil
        quickLook.delegate = nil
        if let quickLookTemporaryURL { try? FileManager.default.removeItem(at: quickLookTemporaryURL) }
        quickLookTemporaryURL = nil
        quickLookData = nil
        quickLookURL = nil
    }

    func paste(_ item: ClipboardItem, asPlainText: Bool = false, pasteSelection: Bool = true) {
        guard !isPasting, let model else { return }
        let selection = pasteSelection ? model.selection : []
        let selected = selection.isEmpty ? [item] : selection
        let joinedSelection = selected.count > 1
        let target = previousApplication
        let store = ClipboardHistoryRuntime.shared.store
        guard let store else {
            close()
            return
        }
        isPasting = true
        Task { @MainActor in
            defer { isPasting = false }
            do {
                let loaded = try await model.fullItems(for: selected)
                guard let target, !target.isTerminated else { throw ClipboardHistoryError.targetUnavailable }
                if !model.isPinned { panel?.orderOut(nil) }
                target.activate(options: [])
                try await Task.sleep(nanoseconds: 120_000_000)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                    throw ClipboardHistoryError.targetUnavailable
                }
                if joinedSelection {
                    let text = loaded.map { ClipboardPanelText.plainText(from: $0.representations, fallback: $0.preview) }
                        .joined(separator: "\n")
                    try await CursorPaster.pasteClipboardHistoryItem([
                        ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
                    ])
                } else {
                    try await store.paste(item, asPlainText: asPlainText)
                }
                closeIfUnpinned()
            } catch {
                panel?.makeKeyAndOrderFront(nil)
                model.errorMessage = error.localizedDescription
            }
        }
    }

    func copy(_ item: ClipboardItem) {
        guard let model else { return }
        Task { await model.copy(item) }
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
        guard let model else { return }
        Task { @MainActor in
            do {
                guard let loaded = try await model.fullItems(for: [item]).first else { return }
                presentQuickLook(for: loaded)
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func presentQuickLook(for item: ClipboardItem) {
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
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let foregroundWindow = visibleWindowFrame(for: previousApplication)
        let screenFrames = screens.map(\.frame)
        let activeIndex = Self.preferredScreenIndex(foregroundWindow: foregroundWindow, pointer: point, screens: screenFrames)
        let pointerScreen = screens.first(where: { $0.frame.contains(point) })
        let option = ClipboardPanelPosition(rawValue: defaults.string(forKey: ClipboardHistorySettings.Keys.windowPosition) ?? "lastLocation") ?? .lastLocation
        let fallbackScreen = NSScreen.main ?? pointerScreen ?? screens[0]
        let screen: NSScreen
        if option == .pointer {
            screen = pointerScreen ?? activeIndex.map { screens[$0] } ?? fallbackScreen
        } else {
            screen = activeIndex.map { screens[$0] } ?? fallbackScreen
        }
        let savedKey = "clipboardHistoryPanelFrame.\(displayID(for: screen))"
        var frame = NSRect(origin: .zero, size: panel.frame.size)
        let visible = screen.visibleFrame
        frame.size = Self.clampedSize(frame.size, to: visible.size)
        panel.minSize = Self.clampedSize(ClipboardHistoryPanel.minimumContentSize, to: visible.size)
        switch option {
        case .lastLocation:
            if let saved = defaults.string(forKey: savedKey) {
                let savedFrame = NSRectFromString(saved)
                if visible.intersects(savedFrame) {
                    frame = Self.restoredFrame(
                        savedFrame,
                        within: visible,
                        minimumSize: ClipboardHistoryPanel.minimumContentSize
                    )
                } else {
                    frame.origin = centeredOrigin(in: visible, size: frame.size)
                }
            } else {
                frame.origin = centeredOrigin(in: visible, size: frame.size)
            }
        case .centerScreen:
            frame.origin = centeredOrigin(in: visible, size: frame.size)
        case .pointer:
            frame.origin = NSPoint(x: point.x + 10, y: point.y - frame.height - 10)
        }
        frame = Self.clampedFrame(frame, to: visible)
        panel.setFrame(frame, display: false)
    }

    private func visibleWindowFrame(for application: NSRunningApplication?) -> CGRect? {
        guard let application,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let windowCandidates = windows.compactMap { entry -> ForegroundWindowCandidate? in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0
            else { return nil }
            return ForegroundWindowCandidate(
                ownerProcessID: application.processIdentifier,
                layer: layer,
                alpha: CGFloat((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1),
                quartzFrame: rect
            )
        }
        guard let quartzFrame = Self.foregroundWindowFrame(
                fromFrontToBack: windowCandidates,
                ownerProcessID: application.processIdentifier
              ),
              let mainScreen = NSScreen.screens.first
        else { return nil }
        return Self.appKitFrame(fromQuartz: quartzFrame, primaryScreenFrame: mainScreen.frame)
    }

    private func centeredOrigin(in rect: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
    }

    static func clampedSize(_ size: CGSize, to bounds: CGSize) -> CGSize {
        CGSize(width: min(max(0, size.width), max(0, bounds.width)), height: min(max(0, size.height), max(0, bounds.height)))
    }

    static func clampedFrame(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var result = frame
        result.size = clampedSize(result.size, to: visible.size)
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }

    static func restoredFrame(_ saved: CGRect, within visible: CGRect, minimumSize: CGSize) -> CGRect {
        var frame = saved
        frame.size.width = max(frame.width, minimumSize.width)
        frame.size.height = max(frame.height, minimumSize.height)
        frame.size = clampedSize(frame.size, to: visible.size)
        return clampedFrame(frame, to: visible)
    }

    static func preferredScreenIndex(foregroundWindow: CGRect?, pointer: CGPoint, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let foregroundWindow,
           let candidate = screens.indices.max(by: {
               intersectionArea(screens[$0], foregroundWindow) < intersectionArea(screens[$1], foregroundWindow)
           }),
           intersectionArea(screens[candidate], foregroundWindow) > 0
        {
            return candidate
        }
        return screens.firstIndex(where: { $0.contains(pointer) })
    }

    struct ForegroundWindowCandidate {
        let ownerProcessID: Int32
        let layer: Int
        let alpha: CGFloat
        let quartzFrame: CGRect
    }

    static func foregroundWindowFrame(
        fromFrontToBack candidates: [ForegroundWindowCandidate],
        ownerProcessID: Int32
    ) -> CGRect? {
        candidates.first(where: {
            $0.ownerProcessID == ownerProcessID && $0.layer == 0 && $0.alpha > 0
                && $0.quartzFrame.width >= 160 && $0.quartzFrame.height >= 100
        })?.quartzFrame
    }

    static func appKitFrame(fromQuartz quartzFrame: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: primaryScreenFrame.minX + quartzFrame.minX,
            y: primaryScreenFrame.maxY - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func displayID(for screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
            ?? screen.localizedName
    }

    private func saveFrame(_ panel: NSPanel) {
        guard let screen = panel.screen else { return }
        let key = "clipboardHistoryPanelFrame.\(displayID(for: screen))"
        defaults.set(NSStringFromRect(panel.frame), forKey: key)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model,
                  Self.shouldHandleKeyEvent(in: event.window, panel: self.panel, isEditing: model.isTextEditorVisible) else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let command = modifiers.contains(.command)
            let option = modifiers.contains(.option)
            let searchHasFocus = self.panel?.firstResponder is NSTextView

            if event.keyCode == 48, !modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control) {
                if modifiers.contains(.shift) { self.panel?.selectPreviousKeyView(nil) }
                else { self.panel?.selectNextKeyView(nil) }
                return nil
            }

            if event.keyCode == 53 {
                if model.isCommandPaletteVisible {
                    model.isCommandPaletteVisible = false
                    return nil
                }
                if !model.query.isEmpty {
                    model.query = ""
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
            if model.isCommandPaletteVisible {
                if event.keyCode == 126 { model.moveCommandSelection(by: -1); return nil }
                if event.keyCode == 125 { model.moveCommandSelection(by: 1); return nil }
                if event.keyCode == 36 || event.keyCode == 76 { model.performSelectedCommand(); return nil }
                return event
            }
            if (event.keyCode == 126 || event.keyCode == 125),
               !command, !option, !modifiers.contains(.control)
            {
                model.moveSelection(by: event.keyCode == 126 ? -1 : 1, extending: modifiers.contains(.shift))
                return nil
            }
            if command, !searchHasFocus, event.charactersIgnoringModifiers?.lowercased() == "c", let item = model.selectedItem {
                self.copy(item)
                return nil
            }
            if command, !searchHasFocus, event.keyCode == 51 {
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

    static func shouldHandleKeyEvent(in window: NSWindow?, panel: NSWindow?, isEditing: Bool) -> Bool {
        guard let panel, let window, window === panel, !isEditing else { return false }
        return true
    }

    private func fileURL(from item: ClipboardItem) -> URL? {
        guard let data = item.representations.first(where: { $0.type == "public.file-url" })?.data else { return nil }
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        // A drag must be able to cross a display edge before the window's screen changes.
        saveFrame(panel)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        clampToVisibleScreen(panel)
        saveFrame(panel)
    }

    private func clampToVisibleScreen(_ panel: NSPanel) {
        guard let screen = panel.screen else { return }
        panel.minSize = Self.clampedSize(ClipboardHistoryPanel.minimumContentSize, to: screen.visibleFrame.size)
        let clamped = Self.clampedFrame(panel.frame, to: screen.visibleFrame)
        if clamped != panel.frame { panel.setFrame(clamped, display: false) }
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.level = .floating
        if !isShowingQuickLook && !isPasting && model?.isTextEditorVisible != true { closeIfUnpinned() }
    }

    func windowWillClose(_ notification: Notification) {
        disposePanel()
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
        if self.panel?.isKeyWindow != true, !isPasting, model?.isTextEditorVisible != true { closeIfUnpinned() }
    }
}

final class ClipboardHistoryPanel: NSPanel {
    static let minimumContentSize = NSSize(width: 740, height: 420)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var level: NSWindow.Level {
        get { .floating }
        set { super.level = .floating }
    }

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
        isMovableByWindowBackground = false
        minSize = Self.minimumContentSize
    }
}
