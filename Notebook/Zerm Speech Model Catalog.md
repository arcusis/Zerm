# Zerm Speech Model Catalog

State of the speech-to-text catalog after 2.8.6 (#326, #323; PRs #333, #334), and the rules for changing it.

## Local

| Model | Group | Notes |
|---|---|---|
| Parakeet Unified 0.6B | English only | Replaces Parakeet V2. `ParakeetUnifiedTranscriptionService` |
| Parakeet TDT-CTC 110M | English only | For 8 GB Macs |
| Parakeet V3 | Multilingual | 25 European languages + auto; no language hint sent |
| Whisper Large v3 Turbo / q5_0 | Multilingual | |
| ivrit.ai Whisper Large v3 Turbo / Large v3 | Hebrew | Pinned HF commit + SHA-256. Forces `he` on auto because its language detection is weak |
| Apple Speech (macOS 26) | Multilingual | Hebrew only if `SpeechTranscriber.supportedLocales` reports it at runtime |

**Retired:** Whisper tiny, base and small (all variants) and Parakeet V2. `RetiredLocalTranscriptionModelMigration` moves selections, including Power Mode JSON, before deleting files.

**Skipped:**
- Canary-1B-v2: beta, English-only prompt.
- Quantized ivrit builds: only an unverified third-party upload exists.

**Recommendations** (`HardwareCapability`) are derived from model metadata plus architecture, RAM and macOS version, with no chip-name parsing. Each need (English, multilingual, Hebrew) gets the best fit within a memory budget; Intel gets whisper.cpp models only.

## Cloud

- **Transport:** requests are built app-side on `CloudHTTP`: ephemeral session (avoids HTTP/3 upload blackholes on VPNs), retries on 429/5xx, and a timeout that scales with audio length. Gemini and Speechmatics stay on LLMkit.
- **Capabilities:** each model declares `TranscriptionCapabilities` (prompt, vocabulary, language hint, streaming, diarization). Requests send only what the model supports, and Model Settings shows only those settings.
- **Output Format:** resolved per request language, and not sent on auto-detect.
- **Custom endpoints:** verified on save with a generated WAV. Presets: Together, DeepInfra, OpenRouter.
- **Retired ids** are migrated by `RetiredCloudTranscriptionMigration`: old Gemini ids, `gpt-4o(-mini)-transcribe` and `voxtral-mini-latest`.
- **Skipped (2026-09):**
  - Azure MAI-Transcribe-2: preview.
  - Fireworks: audio retired.
  - Cloudflare: not OpenAI-compatible.
  - Lemonfox: no model id.

## Dependencies

- FluidAudio is pinned to exact `0.15.7`, and LLMkit to a revision. Never track a branch.
- FluidAudio 0.15.7 links NeMo text normalization, which Zerm deliberately does not call ("one of the best" would become "1 of the best").
- Pre-0.15.7 Parakeet V3 caches lack `JointDecisionv3.mlmodelc`. They count as installed, and the load fetches the file.

Related: [[Zerm Power Mode Inheritance]], [[Zerm File Transcription]], [[Zerm Measuring Model And Audio Claims]]
