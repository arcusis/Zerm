import Foundation
import AppKit
import Carbon
import os

private let logger = Logger(subsystem: "com.arcusis.zerm", category: "CursorPaster")

class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    private static let prePasteDelay: TimeInterval = 0.10
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let unicodeEventDelay: TimeInterval = 0.003
    private static let unicodeEventUTF16Limit = 20
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25

    /// Orca intentionally turns clipboard pastes into `[Pasted text #…]` attachments. Its
    /// editor is also opaque to macOS Accessibility, so AX selected-text insertion is not an
    /// option. Delivering normal Unicode keyboard events matches actual typing and leaves the
    /// user's clipboard untouched. Keep this allow-list narrow because AppKit documents that
    /// some application frameworks may ignore a keyboard event's overridden Unicode string.
    static func prefersClipboardFreeInsertion(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.stablyai.orca"
    }

    /// Splits on Character boundaries so surrogate pairs, emoji sequences, and Hebrew marks are
    /// never torn between Core Graphics keyboard events.
    static func unicodeEventChunks(
        for text: String,
        maxUTF16Units: Int = unicodeEventUTF16Limit
    ) -> [String] {
        guard !text.isEmpty, maxUTF16Units > 0 else { return [] }

        var chunks: [String] = []
        var current = ""
        var currentUTF16Count = 0

        for character in text {
            let value = String(character)
            let valueUTF16Count = value.utf16.count
            if !current.isEmpty, currentUTF16Count + valueUTF16Count > maxUTF16Units {
                chunks.append(current)
                current = ""
                currentUTF16Count = 0
            }
            current.append(character)
            currentUTF16Count += valueUTF16Count
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(_ text: String) -> Task<PasteResult, Never> {
        Task { @MainActor in
            await performPasteSession(text).result
        }
    }

    @MainActor
    static func pasteAtCursorAndWaitUntilPosted(_ text: String) async -> PasteResult {
        await startPasteAtCursor(text).value
    }

    /// Pastes and, alongside it, reads where the caret was so the text can be found again
    /// afterwards.
    ///
    /// The read is issued concurrently with the clipboard write and resolves inside the
    /// pre-paste delay that already exists, so it adds no time to the paste. If it is not
    /// ready by then the paste proceeds regardless and the caller simply gets no anchor.
    @MainActor
    static func pasteAtCursorCapturingAnchor(
        _ text: String
    ) async -> (result: PasteResult, snapshot: AXTextAnchorCapture.PrePasteSnapshot?) {
        await performPasteSession(text, captureAnchor: true)
    }

    /// Replaces a range that `AXTextAnchorCapture` has already verified by selecting it through
    /// Accessibility and posting the standard Paste command. Clipboard contents are restored
    /// under the same session-ownership guard as ordinary dictation paste.
    @MainActor
    static func replaceVerifiedSelectionByPasting(
        _ text: String,
        anchor: AXTextAnchor
    ) async -> PasteResult {
        let pasteboard = NSPasteboard.general
        // Deferred refinement is not the user's direct paste action. It must never silently
        // replace their clipboard, regardless of the preference used for ordinary dictation.
        let savedContents = snapshotClipboard(from: pasteboard)
        let sessionID = UUID().uuidString

        guard ClipboardManager.setClipboard(
            text,
            transient: true,
            sessionID: sessionID,
            on: pasteboard
        ) else {
            logger.error("Failed to prepare refined text for replacement paste")
            return .commandNotPosted
        }

        let refusal = await Task.detached(priority: .userInitiated) {
            AXTextReplacer.prepareSelectionForPaste(anchor, with: text)
        }.value

        guard refusal == nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid else {
            restoreClipboardImmediatelyIfOwned(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
            return .commandNotPosted
        }

        let result = await postPasteCommand()
        scheduleClipboardRestore(
            savedContents,
            expectedText: text,
            sessionID: sessionID,
            on: pasteboard
        )
        return result
    }

    @MainActor
    @discardableResult
    private static func performPasteSession(
        _ text: String,
        captureAnchor: Bool = false
    ) async -> (result: PasteResult, snapshot: AXTextAnchorCapture.PrePasteSnapshot?) {
        let pasteboard = NSPasteboard.general
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        let savedContents = shouldRestoreClipboard ? snapshotClipboard(from: pasteboard) : []
        let sessionID = UUID().uuidString

        // Every accessibility read is a synchronous round-trip into the target process, so
        // it runs detached rather than on the main actor even with a messaging timeout set.
        let anchorTask: Task<AXTextAnchorCapture.PrePasteSnapshot?, Never>? = captureAnchor
            ? Task.detached(priority: .userInitiated) { AXTextAnchorCapture.capture() }
            : nil

        let targetBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if prefersClipboardFreeInsertion(bundleIdentifier: targetBundleIdentifier) {
            await wait(prePasteDelay)
            let snapshot = await anchorTask?.value
            let result = await typeTextWithoutClipboard(text)
            if result == .commandPosted {
                logger.notice("Unicode text events posted without modifying the clipboard")
                return (result, snapshot)
            }
            logger.error("Clipboard-free insertion could not be posted; using paste fallback")
        }

        guard ClipboardManager.setClipboard(
            text,
            transient: shouldRestoreClipboard,
            sessionID: shouldRestoreClipboard ? sessionID : nil,
            on: pasteboard
        ) else {
            logger.error("Failed to prepare clipboard for paste")
            anchorTask?.cancel()
            return (.commandNotPosted, nil)
        }

        await wait(prePasteDelay)

        let snapshot = await anchorTask?.value

        let pasteResult = await postPasteCommand()
        if shouldRestoreClipboard {
            scheduleClipboardRestore(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
        }

        return (pasteResult, snapshot)
    }

    private static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                return nil
            }
        }
    }

    @MainActor
    private static func postPasteCommand() async -> PasteResult {
        if UserDefaults.standard.bool(forKey: "useAppleScriptPaste") {
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        } else {
            return await pasteFromClipboard()
        }
    }

    private static func scheduleClipboardRestore(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        let delay = max(
            UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
            minimumClipboardRestoreDelay
        )

        Task { @MainActor in
            await wait(delay)
            guard pasteboardStillOwnedByPasteSession(pasteboard, expectedText: expectedText, sessionID: sessionID) else {
                return
            }
            pasteboard.clearContents()
            if !savedContents.isEmpty {
                pasteboard.writeObjects(pasteboardItems(from: savedContents))
            }
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText &&
            pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    private static func restoreClipboardImmediatelyIfOwned(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        guard pasteboardStillOwnedByPasteSession(
            pasteboard,
            expectedText: expectedText,
            sessionID: sessionID
        ) else { return }
        pasteboard.clearContents()
        if !savedContents.isEmpty {
            pasteboard.writeObjects(pasteboardItems(from: savedContents))
        }
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript("tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode   = makeScript("tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    // Must run on the main thread. On macOS 26 both the Text Input Source APIs
    // (TISCopyCurrentKeyboardInputSource / TISGetInputSourceProperty, via
    // layoutSwitchesToQWERTYOnCommand) and NSAppleScript execution assert they are
    // called from the main queue — calling them off-main triggers
    // dispatch_assert_queue_fail (EXC_BREAKPOINT / SIGTRAP). This matches the fix in
    // VoiceInk v1.79 for issue #737, and fixes the regression crash reported in
    // Zerm #204 (an earlier off-main dispatch crashed inside the TIS layout read).
    @MainActor
    private static func pasteUsingAppleScript() -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard() async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: "Enable Accessibility for reliable auto-paste",
                    type: .warning
                )
            }
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags   = .maskCommand
        vUp.flags     = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        logger.notice("CGEvents posted for Cmd+V")
        return .commandPosted
    }

    // MARK: - Clipboard-free text insertion

    /// Posts text as ordinary Unicode keyboard input. Newlines are represented as Shift-Return
    /// rather than a bare Return so chat-style editors insert a line break instead of sending.
    @MainActor
    private static func typeTextWithoutClipboard(_ text: String) async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required for clipboard-free text insertion")
            return .commandNotPosted
        }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        for (lineIndex, line) in lines.enumerated() {
            for chunk in unicodeEventChunks(for: String(line)) {
                guard postUnicodeChunk(chunk) else { return .commandNotPosted }
                await wait(unicodeEventDelay)
            }

            if lineIndex < lines.count - 1 {
                guard postLineBreak() else { return .commandNotPosted }
                await wait(unicodeEventDelay)
            }
        }

        return .commandPosted
    }

    private static func postUnicodeChunk(_ chunk: String) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            logger.error("Failed to create Unicode keyboard events")
            return false
        }

        let utf16 = Array(chunk.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
            up.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func postLineBreak() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else {
            logger.error("Failed to create line-break keyboard events")
            return false
        }
        down.flags = .maskShift
        up.flags = .maskShift
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Auto Send Keys

    static func performAutoSend(_ key: AutoSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags   = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags   = .maskCommand
        }

        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
