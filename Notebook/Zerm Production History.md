# Zerm Production History

## Current Branch

`Production` — main and only production branch. All releases tagged here.

The published app is still v2.8.2. The working tree is stamped v2.8.3 (build 283) for the language-fidelity, Instant+Refine, recording-durability, and model-split hotfix. It is not a release until it is committed, signed, and published.

## Historical Commit Snapshot (newest first, 2026-05-22)

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

1. Choose the release identity. `MARKETING_VERSION` is the Apple-facing `Major.Minor.Patch` bundle version and `CURRENT_PROJECT_VERSION` is a strictly increasing integer used by Sparkle. The GitHub release label/tag normally defaults to that bundle version, but `RELEASE_LABEL` / `RELEASE_TAG` may provide a distinct three- or four-component public label. Do not stamp an unpublished identity until it is approved.
2. In the isolated Office Mac worktree, build Debug and Release, run unit tests, and compile/link the UI-test bundle against the exact intended source. UI-test compilation is not UI-test execution; complete the runtime and hardware matrix in [[Zerm Verification Workflow]].
3. Copy the Office-built Release app outside `.release-build` on the signing Mac and package it without a local rebuild. For a decoupled public label, use for example `PREBUILT_APP=/path/to/Zerm.app RELEASE_LABEL=A.B.C.D RELEASE_TAG=vA.B.C.D scripts/release.sh`. The script validates the app, Developer ID signs, notarizes and staples it, then emits exact `Zerm_A.B.C.D_aarch64.dmg` and `Zerm-A.B.C.D-macos.zip` assets plus a signed appcast.
4. Commit the generated `docs/appcast.xml` with the release source, create and push the exact tag, then create a draft GitHub Release and upload both exact assets printed by the script.
5. Run `.github/workflows/release.yml` manually against the draft tag. It verifies the tag format, both filenames, the tagged Xcode versions, appcast label/build/URL/signature, and the ZIP's embedded bundle identity. Publish only after that gate and the installed/quarantined update test pass. The `released` event reruns validation and checks whether the generated website needs a follow-up PR.

Full process: `BUILDING.md`

Related: [[Zerm Overview]], [[Zerm Known Follow Ups]]
