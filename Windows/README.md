# Zerm for Windows

A native Windows port of Zerm (WPF, .NET 9). Dictate anywhere, transcribe files with speakers
identified, read selected text aloud, and clean up text with on-device or cloud AI.
Clipboard history is not part of this port: Windows already has it (Win+V), and dictated text is
deliberately kept out of it.

## Features

| | Windows implementation |
|---|---|
| Dictation hotkeys | Global low-level hook on its own thread. Side-specific modifiers (Right Ctrl by default), Caps Lock, F13 and more, or any custom combination. Toggle, Push to Talk and Hybrid modes. Release watchdog, middle-click, double-Esc cancel, Ctrl+E, Ctrl+1…0 and Alt+1…0 while recording |
| Recorder | Non-activating floating pill (never steals focus). 15-bar visualizer, auto-stop on silence, microphone-drop detection, start/stop sounds, mute while recording (skipped for headphones) |
| Local speech-to-text | whisper.cpp (Whisper.net) on the **GPU through Vulkan** (NVIDIA/AMD/Intel), falling back to CPU. Includes ivrit.ai Hebrew models, Parakeet v2/v3, Moonshine and Zipformer (sherpa-onnx). Silero VAD is bundled. Every download is SHA-256 pinned and resumable |
| Cloud speech-to-text | OpenAI, Groq, ElevenLabs, Deepgram, Mistral, xAI, Soniox, AssemblyAI, Gladia, Gemini, Speechmatics, plus any OpenAI-compatible endpoint |
| AI enhancement | Instant / Instant + Refine / Enhanced. The macOS prompts are generated verbatim from the Swift sources. On-device Gemma 4 / Qwen3 runs through llama.cpp (Vulkan). Also Ollama, OpenAI, Anthropic, Gemini, Groq, Cerebras, Mistral, OpenRouter, Custom and Local CLI. Includes the language guard, trigger words, and clipboard and screen (Windows OCR) context |
| Paste | Clipboard + Ctrl+V via SendInput. Excluded from Win+V history and cloud clipboard. Optional restore. Refine-in-place through UI Automation. Auto-send Enter / Shift+Enter / Ctrl+Enter |
| Power Mode | Per process and per browser URL (address bar read via UI Automation, Chrome/Edge/Firefox/Brave/Opera/Vivaldi/Arc) |
| Transcribe File | Any format Media Foundation can decode. Speaker diarization (pyannote + 3D-Speaker via sherpa-onnx), speaker renaming, TXT/Markdown/SRT/WebVTT/JSON export |
| Read Aloud | Windows voices (offline), Kokoro (on-device), Deepgram, ElevenLabs, OpenAI, Gemini, Cartesia, Inworld. Smart Reading normalizer, plus Retell/Summarize/Explain/Simplify with the on-device LLM |
| Data | History (SQLite) with search, paging, audio, retry, re-enhance and CSV export. Dashboard, vocabulary, word replacements, retention. API keys encrypted with DPAPI |
| Languages | English and Hebrew (right-to-left). macOS translations plus Windows-specific strings |

Not ported: clipboard history (use Win+V), the notch recorder, Apple Speech, CoreML-only paths,
Blue v2 Hebrew TTS (Windows' Hebrew voice is used instead), and auto-learn vocabulary.

## Build and run

Requires the .NET 9 SDK and Windows 10 19041 or later (x64).

```
dotnet build ZermWindows.sln
dotnet test tests/Zerm.Tests
dotnet publish src/Zerm.App -c Release -r win-x64 --self-contained true -o artifacts/Zerm
```

`artifacts/Zerm/Zerm.exe` is a self-contained app (about 360 MB). User data lives in
`%LOCALAPPDATA%\Zerm`; set `ZERM_DATA_DIR` to use another folder.

## Testing

- `dotnet test` runs 95 tests. Unit tests cover the text pipeline, prompts, enhancement executor
  and guard, Power Mode, history, exports and Smart Reading. Real-model tests (Whisper, Parakeet,
  Gemma, Kokoro, diarization, downloader) run when `ZERM_TEST_MODELS` points at a folder laid out
  like `%LOCALAPPDATA%\Zerm`; otherwise they are skipped.
- `Zerm.exe --snapshot <dir>` renders every page, the onboarding steps, the recorder states and a
  toast to PNG files, off-screen.
- `Zerm.exe --selftest <report.txt> <speech.wav>` runs end-to-end dictation inside the app:
  - the hotkey logic (simulated keys, nothing injected into the OS);
  - recording that streams the WAV in place of the microphone;
  - transcription, enhancement and paste into its own test window, read back to verify;
  - Power Mode, file transcription, double-Esc, paste-last, Read Aloud and the real microphone.

  Paste checks are skipped unless the test window is in the foreground.

## Performance notes

- Zerm opts out of Windows EcoQoS power throttling. As a background process it was otherwise
  5–10× slower: Kokoro went from about 9 s to 1 s per sentence and diarization from 27 s to 2 s.
- With a GPU, Whisper Large v3 Turbo transcribes a 7 s dictation in under 1 s. The first ever run
  compiles GPU shaders (up to a minute), so Zerm warms up the model in the background at launch.
- The on-device LLM is also warmed up at launch. A Refine runs in about 0.4 s on GPU (8 s on CPU).

## Architecture

- `src/Zerm.Core` — platform-neutral logic. Text processing, prompts, enhancement, model catalogs
  and downloads, transcription engines, TTS, file transcription, history and settings.
- `src/Zerm.App` — WPF shell. Hooks, recorder, paste, UI Automation, tray, overlay, pages,
  localization.
- `tests/Zerm.Tests` — xUnit tests.

Licensed under GPLv3, like the macOS app (based on VoiceInk by Beingpax). Model licenses are shown
in the app next to each download.
