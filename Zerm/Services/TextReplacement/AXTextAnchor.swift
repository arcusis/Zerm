import Foundation
import AppKit
import ApplicationServices
import Carbon
import os

/// A record of where Zerm's pasted text landed in another application's text field,
/// good enough to find that exact text again a few seconds later — or to refuse to.
///
/// All offsets are UTF-16 code units, because that is what the Accessibility API means by
/// a range. Doing this arithmetic on `Character` counts silently corrupts anything with
/// emoji, combining marks or ZWJ sequences.
/// `AXUIElement` is a CoreFoundation type that Apple documents as safe to use from any
/// thread — only `AXObserver` run-loop sources are run-loop bound, and those are added to
/// the main run loop explicitly. Hence the unchecked conformance.
struct AXTextAnchor: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let role: String?
    let subrole: String?
    /// Range the pasted text occupies, confirmed by reading it back.
    let insertedRange: CFRange
    /// Exactly what we pasted, including the trailing space if one was appended.
    let pastedText: String
}

enum AXTextAnchorCapture {
    private static let logger = Logger(subsystem: "com.arcusis.zerm", category: "AXTextAnchor")

    /// Every Accessibility read is a synchronous IPC round-trip into another process. The
    /// default timeout is six seconds, which against a wedged app would freeze Zerm. No
    /// element handle is used here without this applied first.
    private static let messagingTimeout: Float = 0.15

    /// Snapshot taken before the paste is posted; the caret position in it is what lets us
    /// work out where the text was inserted afterwards.
    struct PrePasteSnapshot: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let bundleID: String?
        let role: String?
        let subrole: String?
        let selection: CFRange
    }

    /// Reads the focused element and caret. Returns nil whenever anything is missing or
    /// off-limits — a nil anchor simply means refine will use its fallback path.
    static func capture() -> PrePasteSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        // Secure input is on process-wide while a password field is focused anywhere.
        // Do not so much as read in that state.
        guard !IsSecureEventInputEnabled() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }

        let role = copyString(element, kAXRoleAttribute)
        let subrole = copyString(element, kAXSubroleAttribute)
        guard subrole != (kAXSecureTextFieldSubrole as String) else { return nil }

        guard let selection = copyRange(element, kAXSelectedTextRangeAttribute) else { return nil }

        return PrePasteSnapshot(
            element: element,
            pid: pid,
            bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            role: role,
            subrole: subrole,
            selection: selection
        )
    }

    /// Waits for the pasted text to actually appear, then verifies it byte-for-byte.
    ///
    /// The caret is expected to end up `pastedText` further along than it started. That
    /// holds even when the paste replaced a selection: insertion still begins at the old
    /// selection's location.
    static func confirm(
        _ snapshot: PrePasteSnapshot,
        pastedText: String,
        pollInterval: TimeInterval = 0.025,
        deadline: TimeInterval = 0.4
    ) async -> AXTextAnchor? {
        guard let (expected, expectedCaret) = expectedInsertion(
            afterSelection: snapshot.selection,
            pastedText: pastedText
        ) else { return nil }
        let end = Date().addingTimeInterval(deadline)

        while Date() < end {
            if let caret = copyRange(snapshot.element, kAXSelectedTextRangeAttribute),
               caret.length == 0,
               caret.location == expectedCaret,
               string(in: snapshot.element, range: expected) == pastedText {
                return AXTextAnchor(
                    element: snapshot.element,
                    pid: snapshot.pid,
                    bundleID: snapshot.bundleID,
                    role: snapshot.role,
                    subrole: snapshot.subrole,
                    insertedRange: expected,
                    pastedText: pastedText
                )
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        logger.debug("Paste not confirmed via accessibility — refine will use the fallback path")
        return nil
    }

    /// Where the pasted text should end up, and where the caret should be afterwards.
    ///
    /// Lengths are UTF-16 code units because that is what an accessibility range counts.
    /// Using `String.count` here would place the range short by one for every emoji and
    /// every combining mark, and the replacement would then overwrite the wrong span.
    static func expectedInsertion(
        afterSelection selection: CFRange,
        pastedText: String
    ) -> (range: CFRange, caret: Int)? {
        let length = pastedText.utf16.count
        guard length > 0, selection.location >= 0 else { return nil }
        return (
            CFRange(location: selection.location, length: length),
            selection.location + length
        )
    }

    // MARK: - Attribute helpers

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func copyRange(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Reads the text occupying `range`, via the parameterized string-for-range attribute.
    static func string(in element: AXUIElement, range: CFRange) -> String? {
        var mutable = range
        guard let parameter = AXValueCreate(.cfRange, &mutable) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }
}
