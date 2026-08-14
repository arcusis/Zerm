# Zerm Notebook

Last updated: 2026-08-10

This notebook captures durable project context for Zerm. Start here, then follow the linked notes relevant to the task.

## Core Notes

- [[Zerm Overview]]
- [[Zerm Architecture]]
- [[Zerm Meeting Recording]] — durable, source-aware meeting capture and processing
- [[Zerm Three Model Platform]] — the STT + TTS + LLM design
- [[Zerm Read Aloud]] — text-to-speech subsystem
- [[Zerm On-Device LLM]] — Gemma via llama.cpp
- [[Zerm Smart Reading]] — human-sounding read-aloud
- [[Zerm Runtime Privacy Model]]
- [[Zerm Auto Paste]]
- [[Zerm Auto Stop Dictation]] — hands-free auto-stop + the self-cancellation gotcha
- [[Zerm Setup And Permissions]]
- [[Zerm Debug Logging]] — user-enabled diagnostic log for field "mic not picked up" reports + real permission check
- [[Zerm Production History]]
- [[Zerm Release Signing]] — Developer ID + notarization pipeline (fixes the Gatekeeper "damaged app" reports)
- [[Zerm Latency Budget]] — measured start/stop costs; the ~45 ms audio floor; the two fixes that mattered
- [[Zerm Native Runtime Teardown]] — why whisper/onnx/llama crash at exit, and the `_exit(0)` rule
- [[Zerm Native Writing Layer Verification]] — how the insertion, permission, and paste behaviours are checked
- [[Zerm Refine In Place]] — instant paste + AI enhancement at once; the AX swap and where it cannot work
- [[Zerm Usage Statistics]] — the durable `usage.store` behind the Dashboard, and why it is a separate store
- [[Zerm Known Follow Ups]]
- [[Zerm Verification Workflow]] — Office Mac build, install, and behavioral release gate

## Current State (2026-08-10)

- **Published baseline:** `Production` is v2.8.1 (build 281). The meeting-recording rearchitecture is an unpublished development worktree targeting v2.8.2 (build 282); it has not yet been packaged, installed or released.
- **Repo is flat:** the Xcode project lives at the **repository root** (`Zerm.xcodeproj`), matching VoiceInk. The old `native-macos/` nesting (a Tauri-era vestige) is gone.
- **Speech workspace:** Recording owns live capture and its History/Enhancements views; Read Aloud and Power Modes remain separate; Permissions, Audio Input, Dictionary and app-wide Settings are shared destinations.
- **Models remain user-selected:** Whisper/FluidAudio/Apple and configured cloud providers serve Dictation and recording transcription; Kokoro/system/cloud voices serve Read Aloud; local and cloud enhancement providers remain explicit choices.
- **Audio-route policy:** Dictation and meeting capture continue when headphones disconnect. Read Aloud only starts on a confirmed wired, Bluetooth/AirPods or USB-headset route and stops with a notification when that safe route is lost; built-in and external speakers are unsafe by default.
- **Verification status:** CI compiles the Debug app, runs unit tests and compiles/links `ZermUITests`. UI execution, real microphone/headset behavior, Developer ID signing/notarization, installation and update-from-public-build remain runtime release gates; see [[Zerm Verification Workflow]].

## Quick Build Reference

```bash
# Run only in the isolated Office Mac worktree; the local development Mac is production.
xcodebuild -project Zerm.xcodeproj -scheme Zerm -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Full build guide: `BUILDING.md`
