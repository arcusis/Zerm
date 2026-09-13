# Zerm Notebook

Last updated: 2026-09-14

This notebook captures durable project context for Zerm. Start here, then follow the linked notes relevant to the task.

## Core Notes

- [[Zerm Overview]]
- [[Zerm Architecture]]
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
- [[Zerm Enhancement Language Fidelity]] — why 2.8.2 let Hebrew take over, and the script-fidelity guard
- [[Zerm Lost Recording 2026-08-17]] — why 14155 and 14161 have no WAV, and the stop-before-transcribe guard
- [[Zerm Usage Statistics]] — the durable `usage.store` behind the Dashboard, and why it is a separate store
- [[Zerm Release 2.8.4 Handoff]] — what is left to ship 2.8.4, and the one gate that must not be skipped
- [[Zerm Measuring Model And Audio Claims]] — how model and capture claims get proved, and the two wrong diagnoses that motivated it
- [[Zerm Power Mode Inheritance]] — why dictation switched models per app, and the inherit-by-default design (2.8.6)
- [[Zerm Enhancement Pipeline]] — frozen per-dictation requests, pipeline order, honest outcomes (2.8.6 rebuild)
- [[Zerm File Transcription]] — Transcribe File with speaker-by-speaker diarization; replaced Meetings in 2.8.6
- [[Zerm Speech Model Catalog]] — local/cloud STT catalog, recommendations, dependency pins
- [[Zerm Dev Build Isolation]] — `com.arcusis.zerm.dev` builds and tests never touch the installed app
- [[Zerm Release 2.8.6 Handoff]] — what is left to ship 2.8.6
- [[Zerm Known Follow Ups]]
- [[Zerm Verification Workflow]] — Office Mac build, install, and behavioral release gate

## Current State (2026-09-14)

- **Published baseline:** `Production` is v2.8.5. Branch `release/2.8.6` carries the whole 2.8.6 release (tracking issue #327, PRs #328–#340), is stamped **2.8.6 / 286**, and is **not released**. See [[Zerm Release 2.8.6 Handoff]].
- **2.8.6 contents:** Power Mode inherits instead of freezing (the model mix-up), enhancement rebuilt, Parakeet streaming keeps the last words, Meetings removed (data deleted on first launch), Transcribe File with speaker identification, new local/cloud model catalog, Dashboard range + History copy, Hebrew throughout the app, VoiceInk v2.11–v2.13 ports, FluidAudio 0.15.7 + LLMkit pinned.
- **Verified by build and tests only:** 410 unit tests, UI-test build. Nothing in 2.8.6 has run on hardware yet.
- **Development builds are isolated** (`com.arcusis.zerm.dev`), so building and testing on the owner's Mac no longer touches the installed app. See [[Zerm Dev Build Isolation]].
- **Repo is flat:** the Xcode project lives at the **repository root** (`Zerm.xcodeproj`), matching VoiceInk.

## Quick Build Reference

```bash
# Run only in the isolated Office Mac worktree; the local development Mac is production.
xcodebuild -project Zerm.xcodeproj -scheme Zerm -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Full build guide: `BUILDING.md`
