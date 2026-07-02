import Foundation
import AppKit
import SelectedTextKit
import os

class SelectedTextService {
    private static let logger = Logger(subsystem: "com.arcusis.zerm", category: "SelectedTextService")

    @MainActor
    static func fetchSelectedText() async -> String? {
        // The ⌘C-based strategies post the synthetic keystroke at the HID tap,
        // where the OS merges in modifiers that are still physically held. The
        // Read Aloud hotkey fires on key-down, so the user's ⌃⌥ (etc.) is still
        // down at this point and would turn the copy into ⌃⌥⌘C — which terminal
        // and TUI apps ignore. Wait for the hotkey to be released first.
        await waitForModifierRelease()

        // `.shortcut` simulates ⌘C and reads the pasteboard (restoring it afterward).
        // It is the only strategy that works in terminal emulators and TUI apps
        // (e.g. Claude Code, cmux), which render text in custom views that do not
        // expose AXSelectedText (.accessibility) and have no standard Edit ▸ Copy
        // menu item (.menuAction). Keep it last so the cheaper strategies win first.
        let strategies: [TextStrategy] = [.accessibility, .menuAction, .shortcut]
        do {
            if let selectedText = try await SelectedTextManager.shared.getSelectedText(strategies: strategies),
               !selectedText.isEmpty {
                return selectedText
            }
        } catch {
            logger.notice("SelectedTextKit failed: \(error.localizedDescription, privacy: .public)")
        }

        // SelectedTextKit's shortcut strategy polls the pasteboard for only 100 ms
        // after posting ⌘C. Embedded terminals (IDE panes, Electron apps, remote
        // UIs) often take longer than that to service a copy, so retry once
        // ourselves with a longer window before giving up.
        return await fetchViaClipboardCopy()
    }

    /// Waits until no modifier keys are physically held (or the timeout passes).
    private static func waitForModifierRelease(timeout: TimeInterval = 1.0) async {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Posts ⌘C itself and polls the pasteboard for up to 600 ms, restoring the
    /// previous pasteboard contents afterward.
    @MainActor
    private static func fetchViaClipboardCopy() async -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let pasteboard = NSPasteboard.general
        // Snapshot into fresh items — items already attached to a pasteboard
        // cannot be written back to it.
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        let initialChangeCount = pasteboard.changeCount

        postCopyKeystroke()

        var copiedText: String?
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if pasteboard.changeCount != initialChangeCount {
                copiedText = pasteboard.string(forType: .string)
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        if pasteboard.changeCount != initialChangeCount {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }

        guard let copiedText, !copiedText.isEmpty else {
            logger.notice("Fallback ⌘C copy produced no text")
            return nil
        }
        return copiedText
    }

    /// Posts ⌘C via CGEvent with a private event source so the synthetic
    /// keystroke does not combine with physically held keys.
    private static func postCopyKeystroke() {
        let source = CGEventSource(stateID: .privateState)
        guard let cDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let cUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            logger.error("Failed to create Cmd+C keyboard events")
            return
        }
        cDown.flags = .maskCommand
        cUp.flags = .maskCommand
        cDown.post(tap: .cghidEventTap)
        cUp.post(tap: .cghidEventTap)
    }
}
