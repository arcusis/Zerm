# Zerm

> Local voice‑to‑clipboard for developers. Tap a key, speak, paste.
> Zero cloud, zero accounts, zero telemetry.

Zerm is a small native menu‑bar app that turns your voice into clean,
structured text — instructions for a coding agent, a Slack message, a polished
email, or just a raw transcript. It runs entirely on your machine.

* **Whisper.cpp** transcribes audio on the GPU (Metal on Apple Silicon).
* **Ollama + Gemma 3** reformats the transcript locally with one of four
  prompt modes.
* The result lands in your clipboard, ready to paste anywhere.

The UI is built with Tauri 2 in the spirit of Apple's Liquid Glass material —
a small floating pill while you speak, and a dashboard window for history,
vocabulary, and settings.

## Features

- **Tap‑to‑toggle hotkey** — defaults to Right Option on macOS, configurable
  in Settings (Right Cmd, Right Shift, Caps Lock, Fn, etc.)
- **Voice‑activity detection** — auto‑stops on ~1.5 s of silence
- **Live audio spectrum** in the floating pill while you speak
- **Multilingual** — auto‑detects the input language; English, Hebrew, Russian,
  Arabic, Chinese, etc.
- **Four prompt modes**
  - **Off** — raw transcript (with a conservative cleanup pass for
    non‑Latin scripts so punctuation/typos still get fixed without
    translation or paraphrasing)
  - **Agent** — instruction for Claude Code or any coding agent
  - **Chat** — short casual message for Slack / WhatsApp / iMessage
  - **Pro** — polished long‑form prose for emails, posts, articles
- **Custom vocabulary** — add company names, acronyms, and identifiers that
  Whisper would otherwise mis‑hear. Each term biases Whisper's decoding.
- **Persistent history** — last 100 dictations, click any to re‑copy
- **Position memory** — drag the pill where you want; it'll be there next
  launch
- **System tray** integration with menu and click‑to‑open dashboard
- **100 % local** — only network call is to your local Ollama at
  `localhost:11434`

## Install

Pre‑built installers will appear on the [Releases](https://github.com/arcusis/Zerm/releases)
page once CI runs against a tag.

| Platform | Status              | Hotkey                                                 |
|----------|---------------------|--------------------------------------------------------|
| macOS    | First‑class         | **Right Option** (modifier‑only, via NSEvent monitor)  |
| Windows  | Works               | **Ctrl + Shift + Space**                               |
| Linux    | Works               | **Ctrl + Shift + Space** (X11; Wayland clipboard may no‑op) |

## Setup

The first time you open Zerm it sets itself up. The dashboard streams
three things automatically:

1. **Whisper model** — the multilingual `ggml-small.bin` (~466 MB) is
   downloaded into the app's data directory.
2. **Ollama** — if not already installed, Zerm downloads the official
   installer for your platform and launches it. Approve the system
   prompt and the Ollama service will come online.
3. **Gemma 3 4B** — pulled through your local Ollama (~3.3 GB).

A progress bar tracks each phase. No terminal commands, no manual
downloads. Just open the app.

The only manual grant required is **Accessibility** on macOS, so Zerm
can observe the Right Option keypress and simulate ⌘V for auto-paste.
System Settings → Privacy & Security → Accessibility. Microphone
permission is requested automatically on first use.

## Usage

1. Launch Zerm. The dashboard opens, and a tray icon appears in your menu
   bar.
2. **Tap your hotkey** (Right Option by default) — the pill appears with a
   pulsing red dot and a live audio spectrum.
3. Speak. Zerm auto‑stops when you stop talking, or you can tap the
   hotkey again.
4. The cleaned text is on your clipboard. Paste it anywhere.

## Configuration

All settings live in the dashboard:

- **Hotkey** — pick from Right Option, Left Option, Right Cmd, Right Shift,
  Right Ctrl, Caps Lock, Fn
- **Prompt mode** — Off / Agent / Chat / Pro
- **Auto‑stop on silence** — toggle VAD on or off
- **Custom vocabulary** — chip‑style library of acronyms and names

Power‑user environment variables:

| Variable               | Effect                                                              |
|------------------------|---------------------------------------------------------------------|
| `ZERM_LLM_MODEL`       | Override the Ollama model. Default `gemma3:4b`.                     |
| `ZERM_WHISPER_MODEL`   | Path to a specific Whisper GGML model file.                         |

State (history, settings, pill position) lives in
`~/Library/Application Support/com.arcusis.zerm/zerm-state.json` on macOS.

## Build from source

```sh
# Prerequisites
brew install cmake ollama
ollama pull gemma3:4b
curl -L -o models/ggml-medium.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin

# Install JS deps and run dev
pnpm install
pnpm tauri dev

# Build a release bundle
pnpm tauri build
```

The first Rust build takes ~2–3 minutes (whisper.cpp + Tauri tree).
Subsequent incremental builds are seconds.

## Privacy

**At runtime,** everything happens on your machine. Microphone audio,
raw Whisper transcripts, AI‑refined output, and persisted history never
leave the device. The only network connection is HTTP to your local
Ollama instance on `localhost:11434`. There are no analytics, no error
reporters, no update servers (yet).

**At first‑run setup,** Zerm makes exactly three outbound connections:

1. `huggingface.co` — downloads the Whisper `ggml‑small.bin` model
   (hash‑pinned and verified on the fly; aborted if the stream exceeds
   500 MB or the SHA‑256 digest doesn't match).
2. `ollama.com` — downloads the official Ollama installer for your
   platform when you click **Install Ollama**. You'll be asked to
   confirm the URL before we download it, and the OS installer itself
   will show its own signature/notarization dialog. The launcher is
   never run silently.
3. `localhost:11434` — your newly installed Ollama pulls the language
   model. This is Ollama talking to its own library, not Zerm.

## Tech stack

- **Tauri 2** — Rust core + WKWebView/WebView2 UI shell
- **whisper.cpp** via `whisper-rs` — on‑device speech‑to‑text with Metal GPU
- **Ollama + Gemma 3** — local LLM for prompt‑mode reformatting
- **cpal** — cross‑platform microphone capture
- **objc2** — native NSEvent global hotkey monitor on macOS
- **arboard** — clipboard write

## Roadmap

- Modifier‑only push‑to‑talk on Windows (Win32 low‑level hook) and Linux
  (evdev or Wayland input grabbers) — today those platforms use a
  Ctrl + Shift + Space combo via the Tauri global‑shortcut plugin
- Streaming Whisper + streaming Ollama for sub‑second perceived latency on
  long recordings
- Optional dock‑icon mode for users who prefer it over the tray
- Plugin API for custom prompt modes

## Contributing

Issues and PRs welcome. The codebase is small enough to read in an
afternoon — `src-tauri/src/lib.rs` is the wiring entry point; the rest is
modules per concern (`audio`, `whisper`, `ollama`, `hotkey`, `state`).

## License

MIT — see [LICENSE](./LICENSE).

Built by [Arcusis](https://arcusis.com) for developers who think faster
than they type.
