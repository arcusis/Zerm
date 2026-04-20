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
| LLM model        | `gemma4:4b` (default)               | Google Gemma 4, ~3GB RAM, intent-aware quality |
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
├── package.json               # Frontend tooling
├── src/                       # Frontend (overlay UI)
│   ├── index.html
│   ├── main.ts
│   └── style.css
├── src-tauri/
│   ├── Cargo.toml
│   ├── tauri.conf.json
│   ├── capabilities/
│   │   └── default.json       # Tauri v2 permissions
│   └── src/
│       ├── main.rs            # Entry point
│       ├── lib.rs             # Tauri app setup, command registration
│       ├── audio.rs           # Mic capture via cpal
│       ├── whisper.rs         # whisper-rs integration + model loading
│       ├── ollama.rs          # Ollama HTTP client + prompt
│       ├── hotkey.rs          # Right Option key handler
│       └── state.rs           # App state (recording flag, model handle)
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
- [ ] Initialize Tauri v2 project
- [ ] Set up git, push to arcusis/Zerm
- [ ] Minimal overlay UI (HTML/CSS)
- [ ] App runs, shows overlay window

### Phase 2 — Hotkey + Audio
- [ ] Right Option global shortcut (tauri-plugin-global-shortcut)
- [ ] Mic capture while key held (cpal)
- [ ] UI reflects listening state

### Phase 3 — ASR
- [ ] whisper-rs integration
- [ ] Download + bundle ggml-small.en model
- [ ] Audio buffer → transcription pipeline
- [ ] UI shows raw transcript

### Phase 4 — LLM Enrichment
- [ ] Ollama client (HTTP to localhost:11434)
- [ ] System prompt + reformatting call
- [ ] Output to clipboard

### Phase 5 — Polish
- [ ] Menu bar icon + quit option
- [ ] Settings: model selection, hotkey config
- [ ] Error states (Ollama not running, no mic, etc.)
- [ ] Build + bundle for macOS

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
