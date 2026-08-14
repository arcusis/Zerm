import Foundation
import AppKit
import os

/// Whether it is worth trying to rewrite text in place inside a given application.
///
/// Native AppKit text views implement the Accessibility text setters properly. Chromium,
/// Electron, and WebKit often expose an exact settable selection range but no working
/// `AXSelectedText` setter. Those simple fields can still be replaced safely by selecting the
/// already-verified range and posting the standard Paste command. Ambiguous contenteditable
/// surfaces expose no settable range and remain fallback-only. Terminals are worse than
/// unsupported: the shell owns the line buffer and accessibility only mirrors a read-only
/// screen, so writing there is meaningless.
actor TargetAppCapabilities {
    static let shared = TargetAppCapabilities()

    enum Verdict: Equatable, Sendable {
        /// The target supports Apple's direct AX selected-text setter.
        case directAccessibility
        /// The target supports exact range selection but replacement must use Cmd-V.
        case clipboardPaste
        /// Known or measured not to support it. Refine still runs; the result is offered
        /// without touching what was already pasted.
        case fallbackOnly
    }

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TargetAppCapabilities")
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
        let verdict = probe(
            element: anchor.element,
            pid: anchor.pid,
            bundleID: bundleID
        )
        logger.notice("Refine capability for \(bundleID, privacy: .public): \(String(describing: verdict), privacy: .public)")
        return verdict
    }

    /// Determines whether Instant + Refine can safely return to the exact inserted range before
    /// any raw text is pasted. Opaque editors (including Orca's current editor) expose no focused
    /// text range; callers must wait for enhancement and paste the final text once instead.
    func verdict(for snapshot: AXTextAnchorCapture.PrePasteSnapshot) -> Verdict {
        guard let bundleID = snapshot.bundleID,
              !Self.terminalBundleIDs.contains(bundleID) else { return .fallbackOnly }

        let verdict = probe(
            element: snapshot.element,
            pid: snapshot.pid,
            bundleID: bundleID
        )
        logger.notice("Pre-paste refine capability for \(bundleID, privacy: .public): \(String(describing: verdict), privacy: .public)")
        return verdict
    }

    private func probe(element: AXUIElement, pid: pid_t, bundleID: String) -> Verdict {
        let canSelectRange = AXTextAnchorCapture.isSettable(
            element,
            kAXSelectedTextRangeAttribute as String
        )
        let canWriteSelectedText = AXTextAnchorCapture.isSettable(
            element,
            kAXSelectedTextAttribute as String
        )
        let prefersPaste = Self.browserBundleIDs.contains(bundleID)
            || isElectron(pid: pid)
        return Self.classify(
            canSelectRange: canSelectRange,
            canWriteSelectedText: canWriteSelectedText,
            prefersPaste: prefersPaste
        )
    }

    nonisolated static func classify(
        canSelectRange: Bool,
        canWriteSelectedText: Bool,
        prefersPaste: Bool
    ) -> Verdict {
        guard canSelectRange else { return .fallbackOnly }
        if canWriteSelectedText, !prefersPaste { return .directAccessibility }
        return .clipboardPaste
    }

    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.brave.Browser",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.operasoftware.Opera",
        "org.mozilla.firefox"
    ]

    /// Chromium ships its framework inside the bundle, which is a cheaper and more
    /// reliable signal than any accessibility probe.
    private func isElectron(pid: pid_t) -> Bool {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let framework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }
}
