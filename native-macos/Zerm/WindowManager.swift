import SwiftUI
import AppKit
import OSLog

class WindowManager: NSObject {
    static let shared = WindowManager()

    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("com.arcusis.zerm.mainWindow")
    private static let onboardingWindowIdentifier = NSUserInterfaceItemIdentifier("com.arcusis.zerm.onboardingWindow")
    private static let mainWindowAutosaveName = NSWindow.FrameAutosaveName("ZermMainWindowFrame")

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "WindowManager")
    private weak var mainWindow: NSWindow?
    private var didApplyInitialPlacement = false

    private override init() {
        super.init()
    }

    func configureWindow(_ window: NSWindow) {
        if let existingWindow = NSApplication.shared.windows.first(where: {
            $0.identifier == Self.mainWindowIdentifier && $0 != window
        }) {
            logger.notice("configureWindow: duplicate detected, reusing existing window")
            window.close()
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        logger.notice("configureWindow: registering main window")

        let requiredStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.styleMask.formUnion(requiredStyleMask)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.title = "Zerm"
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal
        window.isOpaque = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 0, height: 0)
        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        applyInitialPlacementIfNeeded(to: window)
        registerMainWindowIfNeeded(window)
        window.orderFrontRegardless()

        // SwiftUI restores ITS OWN autosave frame (keyed by the full view-hierarchy
        // type string) AFTER this method returns, potentially overriding our placement.
        // Defer a correction that fires once SwiftUI has finished its own restoration.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak window, weak self] in
            guard let window, let self else { return }
            self.ensureWindowIsOnMainScreen(window)
        }
    }

    func configureOnboardingPanel(_ window: NSWindow) {
        if window.identifier == nil || window.identifier != Self.onboardingWindowIdentifier {
            window.identifier = Self.onboardingWindowIdentifier
        }

        let requiredStyleMask: NSWindow.StyleMask = [.titled, .fullSizeContentView, .resizable]
        window.styleMask.formUnion(requiredStyleMask)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .normal
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.title = "Zerm Onboarding"
        window.isOpaque = false
        window.minSize = NSSize(width: 900, height: 780)
        window.makeKeyAndOrderFront(nil)
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.identifier = Self.mainWindowIdentifier
        window.delegate = self
    }

    func showMainWindow() -> NSWindow? {
        guard let window = resolveMainWindow() else { return nil }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return window
    }

    func hideMainWindow() {
        resolveMainWindow()?.orderOut(nil)
    }

    func currentMainWindow() -> NSWindow? {
        resolveMainWindow()
    }

    // MARK: - Private

    private func registerMainWindowIfNeeded(_ window: NSWindow) {
        if window.identifier == nil || window.identifier != Self.mainWindowIdentifier {
            registerMainWindow(window)
        }
    }

    private func applyInitialPlacementIfNeeded(to window: NSWindow) {
        guard !didApplyInitialPlacement else { return }

        if window.setFrameUsingName(Self.mainWindowAutosaveName) {
            // We have a previously saved frame — verify it's on a visible screen.
            // NOTE: window.center() centers on whatever screen the window is currently on,
            // NOT necessarily the main screen. Always use centerOnMainScreen() so stale
            // external-monitor coordinates don't put the window somewhere inaccessible.
            let frame = window.frame
            let onAnyScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
            if !onAnyScreen {
                logger.notice("applyInitialPlacement: saved frame \(NSStringFromRect(frame)) is off all screens — centering on main")
                centerOnMainScreen(window)
                window.saveFrame(usingName: Self.mainWindowAutosaveName)
            }
        } else {
            // No saved frame — center on the main (built-in) screen.
            centerOnMainScreen(window)
            window.saveFrame(usingName: Self.mainWindowAutosaveName)
        }

        didApplyInitialPlacement = true
    }

    /// Deferred correction: if SwiftUI overwrote our placement with stale external-monitor
    /// coordinates, move the window back to the main screen and persist the corrected frame.
    private func ensureWindowIsOnMainScreen(_ window: NSWindow) {
        let frame = window.frame
        let mainScreen = NSScreen.main

        // Check if the window's frame is substantially on the main screen.
        // If not — it ended up on an external monitor due to SwiftUI frame restoration —
        // bring it to the main screen. The user can always move it back to any monitor.
        guard let main = mainScreen else { return }
        let intersection = frame.intersection(main.visibleFrame)
        let windowArea = frame.width * frame.height
        let intersectionArea = intersection.width * intersection.height

        // If less than 50% of the window is on the main screen, snap to main.
        if intersectionArea < windowArea * 0.5 {
            logger.notice("ensureWindowIsOnMainScreen: window mostly off main screen — snapping to main display")
            centerOnMainScreen(window)
            window.saveFrame(usingName: Self.mainWindowAutosaveName)
        }
    }

    /// Center the window on NSScreen.main explicitly. Unlike window.center() which centers
    /// on the window's CURRENT screen, this always targets the built-in/primary display.
    private func centerOnMainScreen(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let x = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
        let y = screenFrame.origin.y + (screenFrame.height - windowSize.height) / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
        logger.notice("centerOnMainScreen: positioned at (\(x, privacy: .public), \(y, privacy: .public)) on \(screen.localizedName, privacy: .public)")
    }

    private func resolveMainWindow() -> NSWindow? {
        if let window = mainWindow { return window }

        logger.notice("resolveMainWindow: weak ref is nil, searching \(NSApplication.shared.windows.count, privacy: .public) windows")

        if let window = NSApplication.shared.windows.first(where: {
            $0.identifier == Self.mainWindowIdentifier
        }) {
            logger.notice("resolveMainWindow: recovered via identifier fallback")
            mainWindow = window
            window.delegate = self
            return window
        }

        logger.error("resolveMainWindow: FAILED — no window with main identifier found")
        return nil
    }
}

extension WindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == Self.mainWindowIdentifier else { return }
        logger.notice("windowWillClose: clearing main window reference")
        window.orderOut(nil)
        mainWindow = nil
        didApplyInitialPlacement = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == Self.mainWindowIdentifier else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
