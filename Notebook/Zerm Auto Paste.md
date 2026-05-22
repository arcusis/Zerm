# Zerm Auto Paste

Zerm pastes the transcribed text at the cursor using `CursorPaster.swift`.

## Default Path — CGEvent Cmd+V

1. `CursorPaster.performPasteSession(text)` runs `@MainActor`
2. `ClipboardManager.setClipboard(text, transient:, sessionID:)` writes text + unique session ID to pasteboard
3. 100 ms pre-paste delay
4. `pasteFromClipboard()` posts CGEvent keyDown/keyUp for virtualKey 0x09 (V) with `.maskCommand`
5. Requires `AXIsProcessTrusted()` — shows warning notification if Accessibility is denied
6. Optional: `scheduleClipboardRestore()` restores original clipboard after delay (default off)
   - Uses session ID to verify pasteboard still contains our text before restoring — prevents the clipboard regression where the restore fired before the app received the paste

## AppleScript Path (off by default)

UserDefault `useAppleScriptPaste = true` enables the AppleScript path:
- `pasteUsingAppleScript()` runs `NSAppleScript.executeAndReturnError` on `DispatchQueue.global(qos: .userInitiated)`
- **Must run off main thread** — macOS 26 added `dispatch_assert_queue_fail` assertion to NSAppleScript when called from main queue
- Handles QWERTY-remapping keyboard layouts via `key code 9` instead of `keystroke "v"`

## Auto-Send

After paste, `CursorPaster.performAutoSend(key)` can send Enter/Shift+Enter/Cmd+Enter via CGEvent to submit (e.g. for chat input). Configured per Power Mode config.

## Paste Fallback

When `commandNotPosted` (Accessibility denied) or when no text field is focused:
- Clipboard still contains the text — user can paste manually
- Notification: "Enable Accessibility for reliable auto-paste" or "Nothing transcribed — audio too short or silent"
- Mini/notch recorder panels have `.canJoinAllSpaces` so they persist across Space switches

## Permissions Required

- **Accessibility** (`com.apple.accessibility.api`): needed for CGEvent injection
- **Screen Recording** (`com.apple.screen-capture`): needed for context-aware features (screen capture context in Power Mode)
- Both are TCC-gated; reset with `make reset-permissions` after rebuild

Related: [[Zerm Setup And Permissions]], [[Zerm Architecture]]
