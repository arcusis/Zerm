# Zerm Production History

## Current Branch

`Production` — main and only production branch. All releases tagged here.

## Recent Commits (newest first, 2026-05-22)

| Hash | Summary |
|------|---------|
| `16d619f` | Remove Tauri prototype, Vite frontend, stale .scpt files, dead code (106 files, ~19 GB freed) |
| `0483bce` | Fix P2: browser multi-instance URL detection (Power Mode); paste fallback confirmed fixed |
| `2e56c35` | Fix P1/P2: WAV header, AudioDeviceManager threading, Fn+F-key, streaming timeout, audio delay, numeric prompt, buffer guard, custom LLM skip-verify |
| `a41ed10` | Fix P0/P1: macOS 26 CursorPaster crash, Settings window menu-bar-only, transcription idle failure, 120s hang timeout, empty transcription notification, DAC mute, hotkey nil-check |
| `7f38b23` | Clarify GPLv3 license and VoiceInk attribution |
| `1894ad6` | Release v1.0.0 |
| `224a3f6` | Add native macOS Zerm app (initial native Swift port) |

## v1.0.x Fixes Summary

### Commit `a41ed10` — P0/P1 fixes
- **macOS 26 crash** — `CursorPaster.pasteUsingAppleScript` now runs on background thread
- **Settings window in menu-bar-only mode** — `NSApp.unhide(nil)` + deferred `setActivationPolicy`
- **First transcription fails after idle** — `runPipeline` waits for model load
- **Transcription hang** — 120 s `withTranscriptionTimeout` in `TranscriptionPipeline`
- **Short phrase no output** — empty transcription shows user notification
- **External DAC stays muted** — `MediaController` sweeps elements 0–8
- **Hotkey silent nil** — `addGlobalMonitorForEvents` nil-check shows permission alert
- **Clipboard regression (VI#722)** — session-ID tracking in `CursorPaster`
- **Gemini model upgrade** — `gemini-3.5-flash` GA

### Commit `2e56c35` — P1/P2 fixes
- **WAV 44-byte hardcoded** — `WhisperTranscriptionService` uses `AudioProcessor.processAudioToSamples` 
- **AudioDeviceManager thread safety** — `@MainActor` added
- **Fn+F-key triggers recording** — companion keyDown monitor during Fn hold
- **Long Parakeet transcripts cut off** — streaming commit timeout 10 s → 30 s
- **First words lost after trigger sound** — `playStartSound` moved post-CoreAudio-ready
- **Numeric word → digit** — English Whisper prompt updated with "One, two, three"
- **Buffer pointer crash** — `channelCount > 0` guard in `AudioFileProcessor`
- **Custom LLM "Not Found"** — `saveCustomAPIKeyWithoutVerification` bypass added

### Commit `0483bce` — P2 fixes
- **Power Mode URL detection with multiple browsers** — `BrowserURLService` targets frontmost regular-policy process, inline script via bundle ID

## Release Process

1. Build locally: `cd native-macos && xcodebuild -scheme Zerm ...` 
2. Sign: Developer ID (or ad-hoc for internal builds)
3. Create DMG, tag git: `git tag vX.Y.Z && git push origin vX.Y.Z`
4. Upload to GitHub Releases: `gh release create vX.Y.Z Zerm_X.Y.Z_aarch64.dmg`
5. CI `release.yml` validates the tag and checks for DMG asset

Full process: `native-macos/BUILDING.md`

Related: [[Zerm Overview]], [[Zerm Known Follow Ups]]
