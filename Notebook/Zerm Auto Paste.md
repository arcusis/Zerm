# Zerm Auto Paste

Auto-paste has been the primary local reliability issue. The user expectation is simple: when automatic paste is enabled, the dictated output should appear in the focused target text field.

## Intended Behavior

1. User focuses the target text field in another app.
2. User presses the Zerm hotkey to start recording.
3. Zerm captures the target app identity at recording start.
4. Zerm records, transcribes, optionally reformats, and writes output to clipboard.
5. If auto-paste is enabled and the job is still current, Zerm restores the original target app and inserts/pastes the output.

## Current macOS Implementation Shape

Recent commits added and refined macOS auto-paste:

- `f6f4b21 Repair local macOS accessibility and pill presentation`
- `d8894ad Fix macOS overlay and signed prerelease trust`
- `b33643e Fix macOS auto-paste focus restore`
- `ab3839b Harden auto-paste and improve about page`
- `ce0d3d6 Make auto-paste permission failures visible`
- `1429e59 Request Accessibility before enabling auto-paste`
- `10afb52 Keep auto-paste gated on Accessibility trust`
- `b8ef4c0 Fix macOS auto-paste execution`
- `ebcbbc8 Add verified macOS auto-paste insertion path`

The current code path in `src-tauri/src/lib.rs` includes direct Accessibility insertion through the focused element, with fallback paste mechanisms such as System Events and CoreGraphics. The app also avoids using Zerm itself as the paste target.

The dashboard now has a diagnostics surface for the last insertion result. The backend reports whether the latest output was only copied, pasted, or blocked by permission/focus failure.

## Key Lessons

- Global hotkey readiness is not equivalent to auto-paste readiness. Auto-paste needs real macOS Accessibility trust.
- Rebuilt local apps may lose effective Accessibility permission even when an old `Zerm.app` entry is visible in System Settings.
- If Zerm is focused at recording start, there is no valid external paste target.
- Clipboard copy must succeed before auto-paste runs; otherwise Zerm risks pasting stale clipboard data.
- The app should report paste permission/focus failures visibly instead of showing a misleading normal copied/done state.

## Current Native Writing-Layer Direction

The next architecture moves paste from a side effect into a native insertion subsystem:

- capture the target app/field context before recording,
- choose app-specific insertion strategies,
- preserve the clipboard where possible,
- report no-target/permission/failure states through the HUD and dashboard,
- keep Windows, Linux X11, and Linux Wayland behavior explicit instead of pretending one paste path covers all platforms.

Related: [[Zerm Setup And Permissions]], [[Zerm Verification Workflow]]
