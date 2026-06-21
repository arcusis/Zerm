import SwiftUI
import SwiftData
import AppKit
import OSLog

class MenuBarManager: ObservableObject {
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MenuBarManager")
    @Published var isMenuBarOnly: Bool {
        didSet {
            UserDefaults.standard.set(isMenuBarOnly, forKey: "IsMenuBarOnly")
            updateAppActivationPolicy()
        }
    }

    private var modelContainer: ModelContainer?
    private var engine: ZermEngine?

    init() {
        self.isMenuBarOnly = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
        updateAppActivationPolicy()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidClose(_ notification: Notification) {
        guard isMenuBarOnly else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let hasVisibleWindows = NSApplication.shared.windows.contains {
                $0.isVisible && $0.level == .normal && !$0.styleMask.contains(.nonactivatingPanel)
            }
            if !hasVisibleWindows && NSApplication.shared.activationPolicy() != .accessory {
                self?.logger.notice("windowDidClose: no visible windows, switching to .accessory policy")
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }

    func configure(modelContainer: ModelContainer, engine: ZermEngine) {
        self.modelContainer = modelContainer
        self.engine = engine
    }
    
    func toggleMenuBarOnly() {
        isMenuBarOnly.toggle()
    }
    
    func applyActivationPolicy() {
        updateAppActivationPolicy()
    }
    
    func focusMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        logger.notice("focusMainWindow: activation policy set to .regular")
        if WindowManager.shared.showMainWindow() == nil {
            logger.error("focusMainWindow: showMainWindow returned nil")
        }
    }
    
    private func updateAppActivationPolicy() {
        // Always defer to the next run loop pass — even when already on the main thread.
        // Calling setActivationPolicy or hideMainWindow synchronously while SwiftUI is still
        // processing a Toggle interaction tears down the window under the live responder chain,
        // which crashes the app.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let application = NSApplication.shared
            if self.isMenuBarOnly {
                self.logger.notice("updateAppActivationPolicy: switching to .accessory (dock icon hidden)")
                application.setActivationPolicy(.accessory)
                WindowManager.shared.hideMainWindow()
            } else {
                self.logger.notice("updateAppActivationPolicy: switching to .regular (dock icon visible)")
                application.setActivationPolicy(.regular)
                WindowManager.shared.showMainWindow()
            }
        }
    }
    
    func openMainWindowAndNavigate(to destination: String) {
        logger.notice("openMainWindowAndNavigate: requested destination=\(destination, privacy: .public), isMenuBarOnly=\(self.isMenuBarOnly, privacy: .public)")

        NSApplication.shared.setActivationPolicy(.regular)
        logger.notice("openMainWindowAndNavigate: activation policy set to .regular")

        // Defer the show to the next run loop so the activation policy change takes
        // effect before we attempt to order the window front.  Without the async, the
        // window may silently fail to appear on macOS when coming from .accessory mode.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard WindowManager.shared.showMainWindow() != nil else {
                self.logger.error("openMainWindowAndNavigate: showMainWindow returned nil — cannot navigate to \(destination, privacy: .public)")
                return
            }

            self.logger.notice("openMainWindowAndNavigate: window shown, posting navigation notification for \(destination, privacy: .public)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                NotificationCenter.default.post(
                    name: .navigateToDestination,
                    object: nil,
                    userInfo: ["destination": destination]
                )
                self?.logger.notice("openMainWindowAndNavigate: navigation notification posted for \(destination, privacy: .public)")
            }
        }
    }

    func openHistoryWindow() {
        guard let modelContainer = modelContainer,
              let engine = engine else {
            logger.error("openHistoryWindow: dependencies not configured (modelContainer=\(self.modelContainer != nil, privacy: .public), engine=\(self.engine != nil, privacy: .public))")
            return
        }
        logger.notice("openHistoryWindow: opening history window")
        NSApplication.shared.setActivationPolicy(.regular)
        logger.notice("openHistoryWindow: activation policy set to .regular")
        HistoryWindowController.shared.showHistoryWindow(
            modelContainer: modelContainer,
            engine: engine
        )
    }
}
