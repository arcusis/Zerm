import SwiftUI
import AppKit
import os

@MainActor
class NotchWindowManager: ObservableObject {
    @Published var isVisible = false
    private var windowController: NSWindowController?
    private var panel: NotchRecorderPanel?
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "NotchWindowManager")

    private let makeView: (NotchWindowManager) -> AnyView
    private let enhancementService: AIEnhancementService

    init(engine: ZermEngine, recorder: Recorder) {
        guard let enhancementService = engine.enhancementService else {
            preconditionFailure("ZermEngine.enhancementService must be non-nil when creating NotchWindowManager")
        }
        self.enhancementService = enhancementService
        self.makeView = { manager in
            AnyView(
                NotchRecorderView(stateProvider: engine, recorder: recorder)
                    .environmentObject(manager)
                    .environmentObject(enhancementService)
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHideNotification),
            name: NSNotification.Name("HideNotchRecorder"),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleHideNotification() {
        hide()
    }

    /// Builds a fresh panel whenever one is not already on screen.
    ///
    /// The panel and its hosting view used to be created once and reused for the app's lifetime,
    /// so a window that stopped rendering — after sleep/wake, a display reconfiguration or any
    /// other WindowServer hiccup — swallowed every later `orderFrontRegardless()`: the hotkey
    /// worked and audio recorded, but no bar was ever drawn until Zerm was relaunched. Such a
    /// window still reports `isVisible == true` with a sane frame, so there is nothing reliable
    /// to test for; rebuilding per dictation means a stale window cannot survive into the next.
    func show() {
        if isVisible { return }
        if panel == nil { initializeWindow() }
        guard let panel else {
            logger.error("Recorder panel could not be shown: no screen available (screens=\(NSScreen.screens.count, privacy: .public))")
            return
        }
        isVisible = true
        panel.show()
    }

    /// Tears the window down rather than ordering it out, so no panel is carried across dictations.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        deinitializeWindow()
    }

    func destroyWindow() {
        isVisible = false
        deinitializeWindow()
    }

    private func initializeWindow() {
        deinitializeWindow()
        guard let metrics = NotchRecorderPanel.calculateWindowMetrics() else { return }
        let newPanel = NotchRecorderPanel(contentRect: metrics.frame)
        let view = makeView(self)
        let hostingController = NotchRecorderHostingController(rootView: view)
        newPanel.contentView = hostingController.view
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
        newPanel.orderFrontRegardless()
    }

    private func deinitializeWindow() {
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }

    func toggle() {
        isVisible ? hide() : show()
    }
}
