# Native Writing-Layer Verification

This checklist covers the native OS behaviors that make Zerm feel like a writing
layer instead of only a transcription app. It is meant for release candidates,
local app replacements, and regressions involving the floating pill,
Accessibility, or auto-paste.

Run the read-only diagnostics script first:

```sh
scripts/verify-native-writing-layer.sh
```

For release artifacts, make signing problems fail the run:

```sh
scripts/verify-native-writing-layer.sh --app /Applications/Zerm.app --strict-release
```

The script is non-destructive by default. The auto-paste self-test can insert
text into the focused application and is only enabled when both an explicit flag
and an acknowledgement environment variable are present:

```sh
ZERM_VERIFY_ALLOW_INPUT=1 scripts/verify-native-writing-layer.sh --run-autopaste-self-test
```

## macOS Signing And Accessibility

Accessibility trust must be evaluated against the currently running binary, not
only the visible row in System Settings. A replaced or ad-hoc signed local build
can leave System Settings showing `Zerm.app` enabled while
`AXIsProcessTrusted()` returns false for the new process.

Release builds must satisfy all of these checks:

- Bundle path is the expected installed bundle, usually `/Applications/Zerm.app`.
- `CFBundleIdentifier` is `com.arcusis.zerm`.
- `codesign --verify --deep --strict` succeeds.
- `codesign -dv --verbose=4` reports `Identifier=com.arcusis.zerm`.
- `TeamIdentifier` is present.
- `Authority=Developer ID Application: ...` is present for public macOS builds.
- `spctl -a -vv --type exec` accepts the app.
- The dashboard permission diagnostics report Accessibility as trusted after the
  app is opened from the installed bundle.

If a local build is ad-hoc signed, expect TCC instability. Remove and re-add the
exact installed `Zerm.app` in System Settings -> Privacy & Security ->
Accessibility after the build is installed. Do not use this local result to
judge release-signing behavior.

Automation is separate from Accessibility. It is only required for the System
Events fallback path. Direct Accessibility insertion and CoreGraphics event
posting can work without Automation, so diagnostics should report them
separately.

## Auto-Paste Self-Test

Use a disposable target such as a scratch TextEdit document.

1. Install the exact app bundle being tested.
2. Open the app once from the installed bundle.
3. Confirm Zerm is enabled in Accessibility for that exact bundle.
4. Focus a scratch text field.
5. Run:

   ```sh
   ZERM_VERIFY_ALLOW_INPUT=1 scripts/verify-native-writing-layer.sh --run-autopaste-self-test
   ```

6. Confirm the generated `ZERM_AUTOPASTE_SELF_TEST_*` token appears exactly
   once in the target field.
7. If the command succeeds but text does not appear, capture:
   - target app name and bundle id,
   - whether the target is native, browser, Electron, terminal, or secure field,
   - dashboard insertion diagnostics,
   - Accessibility and Automation status,
   - whether Zerm was signed, ad-hoc signed, or rejected by Gatekeeper.

The self-test only proves that Zerm can post its current paste path. It does not
replace target-specific testing in real apps.

## Full-Screen Pill Manual Test

The pill must be treated as native overlay behavior. Test across full-screen
Spaces and multiple displays.

1. Open TextEdit, Arc or Chrome, Slack or Discord, and a terminal/editor.
2. Put one target app into macOS full-screen mode.
3. Move the pointer to that full-screen display.
4. Press the Zerm hotkey.
5. Expected result: the floating pill appears immediately above the full-screen
   app on the active display.
6. Speak for two or three seconds.
7. Expected result: the pill stays visible while recording, shows processing,
   then shows copied, pasted, or failure state.
8. Switch Spaces and repeat.
9. Move to a second display and repeat.

Capture failures with these fields:

- target app and bundle id,
- number of displays,
- whether the target is full-screen, tiled, or normal windowed,
- whether the pill did not show, showed behind the app, or appeared on another
  display,
- whether the hotkey still started recording,
- screenshot or screen recording if available.

## Cross-Platform Paste Support Matrix

| Platform | Current expectation | Required permissions and caveats |
| --- | --- | --- |
| macOS | Auto-paste is supported and under active hardening. | Accessibility is required. Automation is only required for the System Events fallback. Release builds must be Developer ID signed for stable TCC trust. |
| Windows | Clipboard copy is supported; native auto-paste should stay gated until the helper path is implemented. | Requires SendInput integration, modifier masking, clipboard sequence tracking, timeouts, helper crash handling, and diagnostics before production auto-paste is claimed. |
| Linux X11 | Clipboard copy is supported; native auto-paste should stay gated until the X11 strategy is implemented. | Requires X11 clipboard plus key synthesis support and dependency checks such as `libxdo`. |
| Linux Wayland | Copy-only or explicit unsupported state. | Wayland paste support is compositor and portal dependent. Do not present it as a generic Linux capability. |

## Release-Candidate Checklist

- Run the normal CI verification commands from the README.
- Run `scripts/verify-native-writing-layer.sh --strict-release` against the
  installed macOS artifact.
- Confirm the dashboard permission diagnostics agree with macOS Accessibility
  after toggling the permission.
- Run the interactive auto-paste self-test in a scratch field.
- Run the target matrix for TextEdit, browser, Electron, terminal/editor, and
  secure field refusal.
- Run the full-screen pill test on at least one full-screen app and one
  multi-display setup.
- Record unsupported or copy-only behavior clearly for Windows, Linux X11, and
  Linux Wayland until those native helpers are production-ready.
