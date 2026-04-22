# Zerm Overview

Zerm is a native Tauri 2 desktop app for local voice-to-clipboard dictation. It records microphone audio, transcribes locally with Whisper through `whisper-rs`, optionally reformats through a local Ollama model, copies the result to the clipboard, and can auto-paste on macOS.

Primary audience: developers and heavy text-entry users who dictate into coding agents, chat, email, notes, PR reviews, and long-form writing.

## Main Components

- `src-tauri/src/lib.rs`: app lifecycle, Tauri commands, setup flow, recording pipeline, clipboard, auto-paste, installer helpers.
- `src-tauri/src/audio.rs`: microphone capture, silence detection, VAD, hard recording caps, audio conversion.
- `src-tauri/src/whisper.rs`: Whisper model loading and transcription.
- `src-tauri/src/ollama.rs`: local Ollama identity checks and rewrite requests.
- `src-tauri/src/state.rs`: settings, history, stats, persistence.
- `dashboard.html` and `src/dashboard.ts`: dashboard UI, settings, setup banners, history, vocabulary.
- `docs/`: GitHub Pages website.

## Platform Model

- macOS hotkey: modifier-only Right Option by default.
- Windows/Linux hotkey: `Ctrl+Shift+Space`.
- Auto-paste is currently macOS-focused. Windows and Linux paste synthesis remains a roadmap item unless implemented later.

Related: [[Zerm Auto Paste]], [[Zerm Setup And Permissions]], [[Zerm Runtime Privacy Model]]
