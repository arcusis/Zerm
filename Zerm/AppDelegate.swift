import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
        MetricKitReporter.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop background prewarms from entering onnxruntime / llama.cpp session construction
        // while the process is shutting down. See ProcessLifecycle.
        ProcessLifecycle.isTerminating = true

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
