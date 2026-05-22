# Zerm Overview

Zerm is a **native macOS Swift/SwiftUI dictation app** based on VoiceInk (GPLv3) by Beingpax. It records microphone audio, transcribes locally or via cloud providers, optionally enhances the text with AI, and pastes the result at the cursor.

Primary audience: developers and heavy text-entry users who dictate into coding agents, chat, email, notes, and long-form writing.

## What Zerm Is Not

- **Not Tauri.** The Tauri/Rust/Vite prototype was fully removed in commit `16d619f`. Nothing from `src-tauri/` exists anymore.
- **Not cross-platform.** macOS only. No Windows or Linux build path.
- **Not a paid app.** GPLv3 open source. The `LicenseManager`/`PolarService` code is a VoiceInk remnant that is still present but hardcoded to `.licensed` — it is dead weight to remove in a future cleanup pass.

## Repository Layout

```
native-macos/          ← Xcode project (the actual app)
  Zerm.xcodeproj
  Zerm/                ← Swift source
    Zerm.swift         ← @main App entry, dependency wiring
    ZermEngine.swift   ← recording/transcription orchestrator
    HotkeyManager.swift
    CursorPaster.swift
    CoreAudioRecorder.swift
    Recorder.swift
    ...
  ZermTests/
  ZermUITests/

docs/                  ← GitHub Pages website (docs/index.html)
Notebook/              ← this Zettelkasten
.github/workflows/     ← ci.yml, release.yml
```

## Main Data Flow

```
Hotkey pressed
  → RecorderUIManager.toggleMiniRecorder()
    → SoundManager.playStartSound()   ← fires AFTER CoreAudio confirms ready
    → ZermEngine.toggleRecord()
      → Recorder.startRecording()     ← CoreAudio AUHAL, background queue
      → WhisperModelManager.loadModel() ← concurrent Task.detached
    → [user speaks]
  → Hotkey released (or auto-stop silence)
    → ZermEngine.toggleRecord() stops recording
    → ZermEngine.runPipeline()
      → waits for isModelLoading == false
      → TranscriptionPipeline.run()
        → session.transcribe() or serviceRegistry.transcribe()
        → TranscriptionOutputFilter
        → WordReplacementService
        → AIEnhancementService.enhance()  ← optional
        → CursorPaster.startPasteAtCursor()
        → onDismiss()
```

## Transcription Providers

| Provider | Type | Key file |
|----------|------|----------|
| Whisper (local) | Local ggml | `WhisperTranscriptionService.swift` |
| Parakeet/FluidAudio | Local ANE | `FluidAudioTranscriptionService.swift` |
| Apple Speech | Local | `NativeAppleTranscriptionService.swift` |
| OpenAI, Gemini, Deepgram, etc. | Cloud | `CloudTranscriptionService.swift` |
| Streaming (Deepgram, ElevenLabs, etc.) | Cloud streaming | `StreamingTranscriptionService.swift` |

Related: [[Zerm Architecture]], [[Zerm Auto Paste]], [[Zerm Runtime Privacy Model]]
