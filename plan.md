# Zerm — Developer Voice-to-Agent App

## Vision

Press and hold Right Option → speak freely (seconds or up to ~15 minutes) → release →
clean, well-structured output lands in clipboard, ready to paste into Claude Code,
any agent, or any text field.

Primary bias: developer instructions. Also handles general prose (notes, emails,
messages) — the LLM detects intent and formats accordingly.

100% local. No cloud. No latency beyond local inference.

---

## Core Flow

```
[Hold Right Option] → mic opens
[Speak]             → audio buffered in memory
[Release]           → whisper.cpp transcribes (Metal GPU)
                    → Ollama LLM reformats to clean coding instruction
                    → result copied to clipboard + shown in overlay
[Paste anywhere]    → done
```

---

## Tech Stack

| Layer            | Technology                          | Rationale                                      |
|------------------|-------------------------------------|------------------------------------------------|
| App shell        | Tauri v2 (Rust)                     | Native binary, tiny footprint, global hotkeys  |
| Frontend         | HTML/CSS/JS (no framework)          | Minimal overlay UI, no build overhead          |
| ASR              | whisper.cpp via `whisper-rs` crate  | Metal GPU on Apple Silicon, near-realtime      |
| Whisper model    | `ggml-base.en` (fast) or `ggml-small.en` | Tiny, English-optimized, <300ms on M-series |
| LLM enrichment   | Ollama HTTP API (localhost:11434)   | Local, swap models freely                      |
| LLM model        | `gemma3:4b` (default)               | Google Gemma 3, ~3GB RAM, intent-aware quality. Override with `ZERM_LLM_MODEL=gemma4:4b` once Gemma 4 lands on Ollama. |
| Audio capture    | `cpal` crate (cross-platform audio) | Native mic access, no Python                   |
| Hotkey           | Tauri global shortcut plugin        | OS-level key capture, Right Option             |
| Output           | System clipboard via Tauri          | Paste anywhere instantly                       |

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  Tauri App                       │
│                                                  │
│  ┌──────────┐    ┌──────────┐    ┌───────────┐  │
│  │  Hotkey  │───▶│  Audio   │───▶│  Whisper  │  │
│  │  Watcher │    │ Capture  │    │  Engine   │  │
│  │ (R.Opt)  │    │  (cpal)  │    │(whisper-rs│  │
│  └──────────┘    └──────────┘    └─────┬─────┘  │
│                                        │         │
│                                   raw text       │
│                                        │         │
│                                  ┌─────▼─────┐  │
│                                  │  Ollama   │  │
│                                  │  Client   │  │
│                                  │(localhost)│  │
│                                  └─────┬─────┘  │
│                                        │         │
│                              clean instruction   │
│                                        │         │
│                    ┌───────────────────▼──────┐  │
│                    │  Clipboard + UI Overlay   │  │
│                    └──────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

---

## UI Design

- **Floating overlay** — small, frameless, always-on-top window
- States:
  - **Idle**: invisible / minimized to menu bar
  - **Listening**: pulsing red dot + "Listening..." label
  - **Processing**: spinner + "Thinking..."
  - **Done**: shows transcription + reformatted output for 3s, then fades
- No dock icon (LSUIElement = true in plist)
- No title bar, borderless window

---

## Directory Structure

```
Zerm/
├── plan.md                    # This file
├── index.html                 # Vite entry (overlay markup)
├── package.json               # pnpm + Vite + Tauri CLI
├── tsconfig.json
├── vite.config.ts
├── src/                       # Frontend (overlay UI)
│   ├── main.ts                # State manager
│   └── styles.css
├── src-tauri/
│   ├── Cargo.toml
│   ├── build.rs
│   ├── tauri.conf.json
│   ├── capabilities/
│   │   └── default.json       # Tauri v2 permissions
│   ├── icons/                 # App icons (placeholder from template)
│   └── src/
│       ├── main.rs            # Entry point
│       ├── lib.rs             # Tauri app setup, command registration
│       ├── audio.rs           # Mic capture via cpal           (Phase 2)
│       ├── whisper.rs         # whisper-rs integration         (Phase 3)
│       ├── ollama.rs          # Ollama HTTP client + prompt    (Phase 4)
│       ├── hotkey.rs          # Right Option key handler       (Phase 2)
│       └── state.rs           # App state                      (Phase 2)
└── models/                    # Whisper GGML model files (gitignored)
    └── .gitkeep
```

---

## LLM System Prompt

The Ollama call uses an intent-aware system prompt: developer instructions are
the primary use case, but plain prose is also supported.

```
You convert raw voice transcriptions into clean, well-structured written output.

Detect the intent:
- If the speaker is asking for code changes, debugging, or agent actions:
  output a precise, actionable instruction for a coding agent (e.g. Claude Code).
- If the speaker is writing general prose (note, email, message, summary):
  output clean, readable prose that preserves their voice and meaning.

Universal rules:
- Fix transcription errors (misheard words, filler: "uh", "um", "like", "you know").
- Use correct technical terminology when coding context is clear.
- Preserve code identifiers, file paths, and proper nouns exactly as spoken.
- Organize long rambling input into clear paragraphs or a numbered list.
- No preamble, no meta-commentary — output the result only.
- Match length to content: short input → short output; long input → structured output.
```

---

## Performance Targets

**Short utterances (< 30s of speech):**

| Step                        | Target     |
|-----------------------------|------------|
| Hotkey → mic open           | < 30ms     |
| Audio → Whisper transcribe  | < 400ms    |
| Whisper → Ollama reformat   | < 1.5s     |
| **Total end-to-end**        | **< 2.5s** |

**Long utterances (up to ~15 min):**

| Step                        | Target                       |
|-----------------------------|------------------------------|
| Whisper transcribe (chunked)| ~0.1× real-time (≤ ~90s)     |
| Ollama reformat             | 5-15s (depends on length)    |
| **Total end-to-end**        | Proportional, not sub-second |

Achievable on Apple M-series with Metal whisper + Gemma 4 4B (4-bit quantized).

---

## Implementation Phases

### Phase 1 — Scaffold
- [x] Initialize Tauri v2 project (vanilla-ts template)
- [x] Git init (push to arcusis/Zerm pending explicit ask)
- [x] Minimal overlay UI (frameless pill with state indicator)
- [x] App runs, shows overlay window

### Phase 2 — Hotkey + Audio
- [x] Right Option global shortcut (rdev — modifier-only, push-to-talk)
- [x] Mic capture while key held (cpal, dedicated thread)
- [x] UI reflects listening state (Tauri events → frontend)

### Phase 3 — ASR
- [x] whisper-rs integration (Metal GPU on Apple Silicon)
- [x] Download ggml-small.en model (475MB, in `models/`, gitignored)
- [x] Audio buffer → mono → resample to 16kHz → transcription pipeline
- [x] UI shows raw transcript via `zerm://transcript` event (in console for now)

### Phase 4 — LLM Enrichment
- [x] Ollama HTTP client (localhost:11434, blocking via tokio runtime)
- [x] Intent-aware system prompt (dev instruction vs. prose)
- [x] Output copied to clipboard via arboard

### Phase 5 — Polish (partial)
- [x] LSUIElement (no dock icon) via embedded Info.plist
- [x] NSMicrophoneUsageDescription embedded
- [x] Error states emitted as `zerm://error` events with overlay flash
- [ ] Menu bar icon + quit option (deferred)
- [ ] Settings UI (model selection currently via env vars: `ZERM_LLM_MODEL`, `ZERM_WHISPER_MODEL`)
- [ ] Build + bundle for macOS (`pnpm tauri build`)

---

## How to run

```sh
# One-time setup (already done)
brew install cmake ollama
brew services start ollama
ollama pull gemma3:4b   # or gemma4:4b once available
# Whisper model already in models/ggml-small.en.bin

# Run
pnpm install
pnpm tauri dev
```

**First-run macOS permission grants required:**
1. **Microphone** — auto-prompts on first hotkey press (uses NSMicrophoneUsageDescription)
2. **Accessibility** — System Settings → Privacy & Security → Accessibility → add `target/debug/zerm` (or the bundled `.app`). Without this, the Right Option hotkey won't fire.

**Usage:**
- Hold Right Option, speak (up to ~15 minutes)
- Release → overlay shows "Thinking…" → output lands in clipboard
- Paste anywhere

**Override defaults via env vars:**
- `ZERM_LLM_MODEL=gemma3:4b` (default; set to `gemma4:4b` once on Ollama)
- `ZERM_WHISPER_MODEL=/path/to/ggml-small.en.bin`

---

## Dependencies (Cargo)

```toml
tauri = { version = "2", features = ["macos-private-api"] }
tauri-plugin-global-shortcut = "2"
tauri-plugin-clipboard-manager = "2"
whisper-rs = { version = "0.13", features = ["metal"] }  # Metal GPU
cpal = "0.15"
reqwest = { version = "0.12", features = ["json"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
```

---

## What We Are NOT Building

- No cloud API calls
- No Electron
- No Python runtime
- No Docker
- No audio playback / TTS
- No login / accounts
- No telemetry
