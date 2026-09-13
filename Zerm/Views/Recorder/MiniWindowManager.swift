import SwiftUI
import AppKit
import os

@MainActor
class MiniWindowManager: ObservableObject {
    @Published var isVisible = false
    private var windowController: NSWindowController?
    private var panel: MiniRecorderPanel?
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MiniWindowManager")

    private let makeView: (MiniWindowManager) -> AnyView

    init(engine: ZermEngine, recorder: Recorder) {
        guard let enhancementService = engine.enhancementService else {
            preconditionFailure("ZermEngine.enhancementService must be non-nil when creating MiniWindowManager")
        }
        self.makeView = { manager in
            AnyView(
                MiniRecorderView(stateProvider: engine, recorder: recorder)
                    .environmentObject(manager)
                    .environmentObject(enhancementService)
                    .environmentObject(engine.dictationSession)
            )
        }
        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHideNotification),
            name: NSNotification.Name("HideMiniRecorder"),
            object: nil
        )
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
        guard let metrics = MiniRecorderPanel.calculateWindowMetrics() else { return }
        let newPanel = MiniRecorderPanel(contentRect: metrics)
        let view = makeView(self)
        let hostingController = NSHostingController(rootView: view)
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
