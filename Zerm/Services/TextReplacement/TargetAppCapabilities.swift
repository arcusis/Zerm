import Foundation
import AppKit
import os

/// Whether it is worth trying to rewrite text in place inside a given application.
///
/// Native AppKit text views implement the Accessibility text setters properly. Chromium
/// and WebKit largely do not: they expose a value and a selection range on simple form
/// controls but no working `AXSelectedText` setter, and `contenteditable` surfaces
/// nothing settable at all — which covers Slack, VS Code, Cursor, Discord, Notion, and
/// most web apps. Terminals are worse than unsupported: the shell owns the line buffer
/// and accessibility only mirrors a read-only screen, so writing there is meaningless.
///
/// Rather than guess, everything outside the terminal deny-list is probed once and the
/// verdict cached per bundle identifier, so the second dictation into a given app costs
/// nothing.
actor TargetAppCapabilities {
    static let shared = TargetAppCapabilities()

    enum Verdict {
        /// Probe succeeded — in-place replacement is available.
        case replaceable
        /// Known or measured not to support it. Refine still runs; the result is offered
        /// without touching what was already pasted.
        case fallbackOnly
    }

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TargetAppCapabilities")
    private var cache: [String: Verdict] = [:]

    /// Terminals and terminal-hosting apps. Never probed, never written to.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "org.alacritty",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "com.qvacua.VimR",
        "org.tabby"
    ]

    func verdict(for anchor: AXTextAnchor) -> Verdict {
        guard let bundleID = anchor.bundleID else { return .fallbackOnly }

        if Self.terminalBundleIDs.contains(bundleID) { return .fallbackOnly }
        if let cached = cache[bundleID] { return cached }

        let verdict = probe(anchor)
        cache[bundleID] = verdict
        logger.notice("Refine capability for \(bundleID, privacy: .public): \(String(describing: verdict), privacy: .public)")
        return verdict
    }

    private func probe(_ anchor: AXTextAnchor) -> Verdict {
        if isElectron(pid: anchor.pid) { return .fallbackOnly }

        let settable = AXTextAnchorCapture.isSettable(anchor.element, kAXSelectedTextRangeAttribute as String)
            && AXTextAnchorCapture.isSettable(anchor.element, kAXSelectedTextAttribute as String)
        return settable ? .replaceable : .fallbackOnly
    }

    /// Chromium ships its framework inside the bundle, which is a cheaper and more
    /// reliable signal than any accessibility probe.
    private func isElectron(pid: pid_t) -> Bool {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let framework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }
}
