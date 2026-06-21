# Zerm Verification Workflow

Steps to verify a change before pushing.

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
  build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Or via Makefile shortcut:
```bash
make local   # builds + copies to ~/Applications/Zerm.app
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

## CI

GitHub Actions `ci.yml` runs on every push to `Production`:
- Swift build (macos-latest, no signing)
- Website HTML lint (checks `id="primary-download"` and download anchor)
- Gitleaks secret scan + hardcoded path check

Related: [[Zerm Overview]], [[Zerm Setup And Permissions]]
