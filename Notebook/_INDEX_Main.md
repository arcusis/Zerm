# Zerm Notebook

Last updated: 2026-08-21

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
- [[Zerm Enhancement Language Fidelity]] — why 2.8.2 let Hebrew take over, and the script-fidelity guard
- [[Zerm Lost Recording 2026-08-17]] — why 14155 and 14161 have no WAV, and the stop-before-transcribe guard
- [[Zerm Usage Statistics]] — the durable `usage.store` behind the Dashboard, and why it is a separate store
- [[Zerm Measuring Model And Audio Claims]] — how model and capture claims get proved, and the two wrong diagnoses that motivated it
- [[Zerm Known Follow Ups]]
- [[Zerm Verification Workflow]] — Office Mac build, install, and behavioral release gate

## Current State (2026-08-21)

- **Published baseline:** `Production` is v2.8.3. Branch `fix/local-llm-thinking-empty-enhancement` (PR #308, draft) carries the 2.8.4 work and is **not released** — held deliberately until browser meeting capture is confirmed on real hardware.
- **2.8.4 contents, measured:** on-device enhancement no longer returns an empty string (#307); History rows blanked by that defect are repaired on launch; the model catalogue is rebuilt on benchmark evidence; the enhancement prompt is rewritten on measurement; enhancement is **3.6x faster** via prompt prefix caching; meeting audio gaps are padded so the call track matches the meeting (#309); meetings transcribe after Stop instead of during capture (#310); the release DMG has a branded installer window.
- **2.8.4 contents, unverified:** browser-based meeting capture, and a real signed/notarized release build. Both need hardware this branch has not had.
- **Enhancement defaults to Gemma 4 E2B** for both jobs — the only model measured that preserves mixed Hebrew/English/Russian. See [[Zerm On-Device LLM]].
- **Repo is flat:** the Xcode project lives at the **repository root** (`Zerm.xcodeproj`), matching VoiceInk.
- **Speech workspace:** Recording owns capture and its History/Enhancements views; Read Aloud and Power Modes remain separate; Permissions, Audio Input, Dictionary and app-wide Settings are shared destinations.
- **Models remain user-selected:** Whisper/FluidAudio/Apple and configured cloud providers serve Dictation and recording transcription; Kokoro/system/cloud voices serve Read Aloud. Enhancement offers 8 cloud providers plus Ollama, Local CLI, On-Device and Custom, over `LLMkit` and a native Anthropic client — not vendor SDKs.
- **Audio-route policy:** Dictation and meeting capture continue when headphones disconnect. Read Aloud only starts on a confirmed wired, Bluetooth/AirPods or USB-headset route and stops with a notification when that safe route is lost.
- **Verification status:** CI compiles the Debug app, runs unit tests and compiles/links `ZermUITests`. UI execution, real microphone/headset behavior, Developer ID signing/notarization, installation and update-from-public-build remain runtime release gates; see [[Zerm Verification Workflow]] and [[Zerm Measuring Model And Audio Claims]].

## Quick Build Reference

```bash
# Run only in the isolated Office Mac worktree; the local development Mac is production.
xcodebuild -project Zerm.xcodeproj -scheme Zerm -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Full build guide: `BUILDING.md`
