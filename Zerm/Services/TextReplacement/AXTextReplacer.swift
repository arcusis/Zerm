import Foundation
import AppKit
import ApplicationServices
import Carbon
import os

/// Swaps already-pasted text for its refined version, in place, without keystrokes.
///
/// The guarantee this type exists to provide is one-directional: it can fail to improve
/// the text, but it must never damage it. Every check below therefore fails closed, and
/// the caller treats a refusal as completely ordinary.
enum AXTextReplacer {
    private static let logger = Logger(subsystem: "com.arcusis.zerm", category: "AXTextReplacer")

    /// Below this length an accidental match on a shifted range stops being far-fetched,
    /// and a short phrase gains little from refinement anyway. This mirrors the reasoning
    /// behind the existing "skip short transcriptions" enhancement setting.
    private static let minimumReplaceableLength = 12

    private static let replaceableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String
    ]

    enum Refusal: String, Sendable {
        case notTrusted
        case secureInput
        case appChanged
        case focusChanged
        case elementGone
        case unsupportedRole
        case textEdited
        case notSettable
        case tooShort
        case nothingToDo
        /// Passed every gate but the write or its read-back did not land.
        case writeFailed
    }

    /// Re-runs every check against live state. Cheap checks first, so an app switch costs
    /// no cross-process reads at all.
    static func canReplace(_ anchor: AXTextAnchor, with enhanced: String) -> Refusal? {
        validate(anchor, with: enhanced, requiresSelectedTextSetter: true)
    }

    /// Validates the same fail-closed contract as direct AX replacement, then selects the exact
    /// verified range for a standard Paste command. This supports simple Chromium/Electron text
    /// fields without pretending their unreliable `AXSelectedText` setter works.
    static func prepareSelectionForPaste(_ anchor: AXTextAnchor, with enhanced: String) -> Refusal? {
        if let refusal = validate(anchor, with: enhanced, requiresSelectedTextSetter: false) {
            return refusal
        }

        var range = anchor.insertedRange
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                anchor.element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success else { return .writeFailed }

        guard let confirmed = AXTextAnchorCapture.copyRange(
            anchor.element,
            kAXSelectedTextRangeAttribute as String
        ), confirmed.location == range.location, confirmed.length == range.length else {
            return .writeFailed
        }

        // Selection itself must not have changed the field, and no edit may have landed between
        // validation and selection. Cmd-V is posted only after this final byte-for-byte readback.
        guard AXTextAnchorCapture.string(in: anchor.element, range: range) == anchor.pastedText else {
            return .textEdited
        }
        return nil
    }

    private static func validate(
        _ anchor: AXTextAnchor,
        with enhanced: String,
        requiresSelectedTextSetter: Bool
    ) -> Refusal? {
        guard AXIsProcessTrusted() else { return .notTrusted }
        guard !IsSecureEventInputEnabled() else { return .secureInput }

        let trimmed = enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, enhanced != anchor.pastedText else { return .nothingToDo }
        guard anchor.pastedText.utf16.count >= minimumReplaceableLength else { return .tooShort }

        // The frontmost-app check belongs to the caller: it touches AppKit, and this
        // function runs off the main actor.
        guard let role = anchor.role, replaceableRoles.contains(role) else { return .unsupportedRole }
        guard anchor.subrole != (kAXSecureTextFieldSubrole as String) else { return .secureInput }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .elementGone }
        // CFEqual, not ==: the latter compares references. Some Chromium and WebKit hosts
        // hand back a fresh wrapper on every query and will compare unequal here — a false
        // negative, which is the safe direction to be wrong in.
        guard CFEqual(focused as! AXUIElement, anchor.element) else { return .focusChanged }

        // The decisive check. Accessibility ranges are absolute offsets, so an edit before
        // our range shifts it and this comparison fails; an edit after it leaves our
        // offsets valid and replacing is still correct.
        guard AXTextAnchorCapture.string(in: anchor.element, range: anchor.insertedRange) == anchor.pastedText else {
            return .textEdited
        }

        guard AXTextAnchorCapture.isSettable(anchor.element, kAXSelectedTextRangeAttribute as String) else {
            return .notSettable
        }
        if requiresSelectedTextSetter,
           !AXTextAnchorCapture.isSettable(anchor.element, kAXSelectedTextAttribute as String) {
            return .notSettable
        }

        return nil
    }

    /// Selects the pasted range and writes the refined text over it.
    ///
    /// These are two separate calls — macOS has no atomic accessibility text-replace — but
    /// both are serviced in order on the target's main thread with no user input able to
    /// interleave in the millisecond between them, and the selection is read back before
    /// anything is written. That read-back is what makes it safe rather than atomic.
    @discardableResult
    static func replace(_ anchor: AXTextAnchor, with enhanced: String) -> Bool {
        var range = anchor.insertedRange
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return false }

        guard AXUIElementSetAttributeValue(
            anchor.element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success else { return false }

        guard let confirmed = AXTextAnchorCapture.copyRange(anchor.element, kAXSelectedTextRangeAttribute as String),
              confirmed.location == range.location,
              confirmed.length == range.length else {
            logger.notice("Selection read-back did not match — leaving the pasted text untouched")
            return false
        }

        guard AXUIElementSetAttributeValue(
            anchor.element,
            kAXSelectedTextAttribute as CFString,
            enhanced as CFString
        ) == .success else { return false }

        let written = CFRange(location: range.location, length: enhanced.utf16.count)
        if AXTextAnchorCapture.string(in: anchor.element, range: written) != enhanced {
            // Nothing safe to roll back to at this point: attempting a repair write would
            // be a second unverified mutation. Report it and leave the field alone.
            logger.error("Refined text read-back mismatch after write")
            return false
        }

        var caret = CFRange(location: range.location + enhanced.utf16.count, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(anchor.element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }

        return true
    }
}
