import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    /// Synchronous last-chance cleanup for capture sessions before native-runtime teardown is
    /// skipped with `_exit`. Recording code must stop callbacks, close writers, and journal an
    /// interrupted state here; lengthy inference and network work must already be cancelled.
    var onWillTerminate: (() -> Void)?

    #if DEBUG
    private var uiTestWindowPresentationAttemptsRemaining = 40
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // LSUIElement/menu-bar launches begin life as accessory processes. SwiftUI may decide
        // not to instantiate the default WindowGroup if that policy is still active when its
        // scene is connected. The explicit UI-test flag is the sole exception: establish a
        // foreground application before scene creation. Product launches never enter this path.
        if UITestLaunchConfiguration.current.isEnabled {
            _ = NSApplication.shared.setActivationPolicy(.regular)
        }
        #endif
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UITestLaunchConfiguration.current.isEnabled {
            #if DEBUG
            presentUITestWindowWhenAvailable()
            #endif
        } else {
            menuBarManager?.applyActivationPolicy()
            MetricKitReporter.shared.start()
        }
    }

    #if DEBUG
    /// SwiftUI attaches the WindowGroup asynchronously after the application delegate finishes
    /// launching. Retry for a short, bounded interval, then leave the UI assertion to report a
    /// real launch failure rather than manufacturing a separate test window.
    private func presentUITestWindowWhenAvailable() {
        guard UITestLaunchConfiguration.current.isEnabled else { return }

        let application = NSApplication.shared
        _ = application.setActivationPolicy(.regular)
        // XCUIApplication.launch() waits for the process itself to become foreground before
        // the test can send Cmd-N. Activate immediately, even if SwiftUI has not attached the
        // WindowGroup yet; the bounded retry below will front the real window once it exists.
        application.unhide(nil)
        application.activate(ignoringOtherApps: true)

        if let window = WindowManager.shared.currentMainWindow() {
            window.makeKeyAndOrderFront(nil)
            return
        }

        if let window = application.windows.first(where: { window in
            window.level == .normal
                && window.canBecomeMain
                && !window.styleMask.contains(.nonactivatingPanel)
        }) {
            WindowManager.shared.configureWindow(window)
            return
        }

        guard uiTestWindowPresentationAttemptsRemaining > 0 else { return }
        uiTestWindowPresentationAttemptsRemaining -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.presentUITestWindowWhenAvailable()
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        // Stop background prewarms from entering onnxruntime / llama.cpp session construction
        // while the process is shutting down. See ProcessLifecycle.
        ProcessLifecycle.isTerminating = true

        // Capture owns open audio files that are not covered by SwiftData/defaults. Give the
        // application-scoped recording coordinator a synchronous chance to finalize them before
        // `_exit` intentionally bypasses Swift and C++ destructors.
        onWillTerminate?()

        // Flush anything that genuinely needs writing, then leave via _exit().
        //
        // `exit()` runs __cxa_finalize_ranges, which destroys ggml's *global*
        // vector<unique_ptr<ggml_metal_device>> inside whisper.framework. That calls
        // ggml_metal_rsets_free (ggml-metal-device.m:612), which hits ggml_abort() because
        // ggml's own rsets init block is still spinning in a usleep loop on a background
        // queue (ggml-metal-device.m:597) — so every quit after a transcription died with
        // SIGABRT. The device lives in a library global, so releasing the whisper context
        // from Swift does not remove it and does not help (verified: it still crashed).
        // Nothing in that teardown path is ours and none of it needs to run to quit safely:
        // transcripts are committed to SwiftData as they complete, and defaults are flushed
        // on the line above. Skipping static destruction is the fix.
        UserDefaults.standard.synchronize()
        _exit(0)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let menuBarManager = menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.showMainWindow() != nil {
                return false
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
