# Zerm Notebook

Last updated: 2026-07-27

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
- [[Zerm Known Follow Ups]]

## Current State (2026-07-13)

- Branch: `Production` · Version: `2.6.1` (build 261)
- **Repo is flat:** the Xcode project lives at the **repository root** (`Zerm.xcodeproj`), matching VoiceInk. The old `native-macos/` nesting (a Tauri-era vestige) is gone.
- **Three on-device models:** Whisper (STT), Kokoro (TTS), Gemma (agentic LLM) — each auto-downloaded and managed in-app; cloud providers optional per task.
- **Read Aloud** ships with smart reading (instant cleanup + optional on-device AI rewrite).
- CI builds the Swift app on every PR (all actions SHA-pinned per repo policy).

## Quick Build Reference

```bash
# From the repo root
make install            # build + ad-hoc sign + install to /Applications (resets TCC)
make reset-permissions  # tccutil reset Accessibility + ScreenCapture
```

Full build guide: `BUILDING.md`
