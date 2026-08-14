# Zerm Three Model Platform

Zerm's defining architecture: the experience is powered by **three on-device AI models**, each owned and installed by the app, each able to run fully offline.

```mermaid
flowchart LR
    A[🎙️ Whisper<br/>Speech-to-Text] --> B[🧠 Gemma<br/>Agentic LLM]
    C[Selected text] --> B
    B --> D[🔊 Kokoro<br/>Text-to-Speech]
    A -. or paste .-> P[Cursor]
```

The middle model (**Gemma**) is the agentic layer serving *both* sides: it cleans speech-to-text output for accuracy and de-robotizes text-to-speech.

| | STT | TTS | LLM |
|---|---|---|---|
| Default | Whisper (ggml) | Kokoro-82M | Gemma 4 E2B QAT Q4_0 |
| Engine | `whisper.cpp` | `sherpa-onnx` | `llama.cpp` |
| ~Size | 150 MB–3 GB | ~330 MB | ~3.35 GB |
| Manager | `WhisperModelManager` | `KokoroModelManager` | `LocalLLMModelManager` |
| Path | `…/WhisperModels/` | `…/TTSModels/` | `…/LLMModels/` |

All live under `~/Library/Application Support/com.arcusis.zerm/` (outside the bundle → survive reinstalls). Every model uses the same download UX (manager classes are mirrors); cloud providers remain optional per task.

The LLM policy is intentionally memory-first: E2B is the default regardless of installed RAM, larger models require an explicit selection, contexts are capped at 8K, and the loaded engine is released after two idle minutes or sooner under memory pressure.

Related: [[Zerm Read Aloud]], [[Zerm On-Device LLM]], [[Zerm Smart Reading]], [[Zerm Architecture]]
