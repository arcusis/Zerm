# Zerm Verification Workflow

Steps to verify a change before pushing. Since 2.8.6, `make test` and `make dev-app` build under the development bundle id `com.arcusis.zerm.dev` and never touch the installed app, so they are safe on the owner's Mac (see [[Zerm Dev Build Isolation]]). `make local` and `make install` still replace the installed app: never run them on the owner's Mac without an explicit request.

## Build

```bash
xcodebuild \
  -project Zerm.xcodeproj \
  -scheme Zerm \
  -configuration Debug \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  build
```

Or via Makefile shortcut:
```bash
make local   # builds + copies to ~/Downloads/Zerm.app
```

## Install + Reset Permissions

```bash
make install   # build → install to /Applications → reset TCC → relaunch
```

This runs:
1. `make local` 
2. `pkill -x Zerm`
3. `ditto` to `/Applications/Zerm.app`
4. `lsregister` (clears Launchpad duplicates)
5. `defaults write com.apple.dock ResetLaunchPad -bool true && killall Dock`
6. `tccutil reset Accessibility com.arcusis.zerm`
7. `tccutil reset ScreenCapture com.arcusis.zerm`
8. `open /Applications/Zerm.app`

## Core Smoke Test

1. Press hotkey → mini recorder appears and start sound plays
2. Speak a phrase → release hotkey
3. Transcription appears and is pasted at cursor
4. Open Settings → all sections load without crash
5. Toggle "Hide Dock Icon" → window hides; click Settings from menu bar → window reappears
6. Power Mode → configure a browser URL trigger → open that URL → verify prompt applies

## Runtime Gate

1. Simulate built-in speaker, wired, Bluetooth/AirPods, USB headset, unknown and disconnect routes. Dictation must continue, and "skip mute with headphones" must follow the confirmed route.
2. Run keyboard-only, VoiceOver/accessibility, Reduce Motion, dark/high-contrast, narrow/full-screen, English, Hebrew and RTL UI flows.
3. Install the resulting app on the Office Mac and repeat the no-microphone-safe flows. Record the exact build and test artifacts before release.

The Meeting Recording gate was retired with the Meetings module in 2.8.6.

An Office Mac `build-for-testing` success proves that the UI-test bundle links; it does not prove that UI tests executed. XCTest automation requires an unlocked Aqua session and the user-granted automation permission for Xcode's test runner. Record the `.xcresult` from an executed run. The no-microphone Office Mac can cover injected capture, deterministic fixtures and failure paths, but final release acceptance still needs real microphone input plus wired, AirPods/Bluetooth and USB-headset route/disconnect checks. VoiceOver, keyboard-only, Reduce Motion, contrast, English/Hebrew and RTL remain runtime gates rather than compile-time claims.

## Release Packaging Without a Local Rebuild

Copy the Office-built unsigned Release app to the signing Mac, outside `.release-build`, then run:

```bash
PREBUILT_APP=/path/to/Zerm.app \
  RELEASE_LABEL=A.B.C.D RELEASE_TAG=vA.B.C.D \
  scripts/release.sh
```

This validates the app's bundle identifier, version, build and arm64 executable before and after staging; signs and notarizes the copy; and exports both `Zerm_<release-label>_aarch64.dmg` and `Zerm-<release-label>-macos.zip`. Omit `RELEASE_LABEL` and `RELEASE_TAG` when the GitHub label should match the bundle version. A distinct label affects only the tag, asset names and appcast presentation/URL; the bundle version remains Apple's three-component form and the strictly increasing build controls Sparkle ordering. Packaging is not complete until both assets exist, the appcast enclosure has a valid Sparkle signature, Gatekeeper assessment succeeds, the manual Release workflow validates the draft tag, and the installed quarantined build passes the runtime matrix. Do not use `make release` for this path: its `setup` prerequisite is a local build/dependency workflow.

## CI

GitHub Actions `ci.yml` runs on every push to `Production`:
- Debug Swift build, `ZermTests`, and `ZermUITests` compile/link via `build-for-testing` without UI execution (macOS runner, signing disabled)
- Website generation/integrity checks, including the primary download anchor
- Repo-specific hardcoded-home-path and Sparkle appcast-integrity checks

GitGuardian secret detection and CodeQL are separate required repository checks; `ci.yml` does not run Gitleaks because repository Actions policy only permits selected, SHA-pinned actions. CI does not prove Developer ID signing/notarization, UI-test execution, installation, audio hardware behavior or an end-to-end update from a previous public build.

Related: [[Zerm Overview]], [[Zerm Setup And Permissions]]
