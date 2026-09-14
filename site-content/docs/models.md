---
title: Models
eyebrow: Setup
summary: Which transcription model to use, what each one costs you in speed, size and memory, and how local and cloud differ.
---

Zerm separates the model that turns speech into text from the model that improves that
text afterwards. This page covers the first one. For the second, see
[AI enhancement](enhancement.html).

The same model list serves dictation and [Transcribe File](transcribe-file.html).

## Finding a model

The models screen has four filters:

- **Recommended** — the default view. Zerm looks at your chip, memory, and macOS version
  and picks the best fit for English, for many languages, and for Hebrew, plus the
  flagship model of every cloud provider you have added a key for.
- **Local** — every on-device model. Narrow it with **English only**, **Multilingual**,
  or **Great in Hebrew**.
- **Cloud** — every cloud model, filterable by provider.
- **Custom** — OpenAI-compatible endpoints you add yourself.

Cards carry badges for what matters when choosing: **Streaming**, **Speaker labels**,
**Uses Dictionary**, and how well the model handles Hebrew (**Great in Hebrew**,
**Hebrew**, or **No Hebrew**).

## Local models

Local models download once and then run entirely on your Mac. No key, no account, no
network — dictation keeps working on a plane.

| Model | Size | Languages | Notes |
| --- | --- | --- | --- |
| Parakeet Unified | 614 MB | English only | The best English model for most Apple Silicon Macs. |
| Parakeet 110M | 228 MB | English only | Small and very fast. Leaves memory free on 8 GB Macs. |
| Parakeet V3 | 494 MB | English + 25 European languages | Detects the language itself. Supports real-time streaming. No Hebrew. |
| Large v3 Turbo | 1.5 GB | Multilingual | Whisper. The most accurate general multilingual model. |
| Large v3 Turbo (Quantized) | 547 MB | Multilingual | Nearly the same accuracy for a third of the disk. |
| ivrit.ai Large v3 Turbo | 1.6 GB | Hebrew and English | Whisper tuned for Hebrew by ivrit.ai. |
| ivrit.ai Large v3 | 3.1 GB | Hebrew and English | Slower and more accurate. Needs a Mac with 24 GB of memory or more. |
| Apple Speech | — | Multilingual | Built into macOS. Nothing to download. **Requires macOS 26.** |

**Parakeet** runs through FluidAudio and needs Apple Silicon. **Whisper** models run on
`whisper.cpp`, and you can import your own fine-tuned one — see
[custom local models](custom-local-whisper-models.html).

**The ivrit.ai models** treat Auto as Hebrew and keep the English words you mix in.
Choose English only when you will dictate nothing but English.

**Apple Speech** offers Hebrew only if your copy of macOS reports that it supports it.

### Retired models

Whisper Tiny, Base, and Small (including the English variants) and Parakeet V2 are no
longer offered. If you were using one, Zerm moves you — and any
[Power Mode](power-mode.html) that pinned it — to its replacement: Parakeet Unified for
the English models on Apple Silicon, Large v3 Turbo (Quantized) otherwise. The old files
are deleted.

The replacement is not downloaded for you. The Default Model card says a download is
required, with a button to start it.

## Streaming and live preview

With streaming, text appears in the recorder while you are still talking.

- **Parakeet V3** is the local model that streams. Its card has a **Real-time** switch,
  on by default once the model is downloaded.
- **Cloud models** marked **Streaming** get the same **Real-time** switch once their key
  is configured.
- **Show Live Text Preview**, in Model Settings, decides whether the recorder shows that
  text as it arrives. On by default.

When you stop, Zerm transcribes the complete recording once more, so the last words you
said are never cut off by the live preview.

## Cloud models

Cloud models send your audio to a provider. Nothing is contacted until you add a key and
select the model, and you can keep local and cloud models installed side by side.

| Provider | Models |
| --- | --- |
| OpenAI | GPT Transcribe |
| Gemini | Gemini 3.5 Transcribe |
| ElevenLabs | Scribe V2 |
| Soniox | Soniox V5 |
| AssemblyAI | Universal 3.5 Pro, Universal 2 |
| Deepgram | Nova 3, Nova 3 Medical |
| Groq | Whisper Large v3 Turbo, Whisper Large v3 |
| Mistral | Voxtral Mini Transcribe 2 |
| Speechmatics | Speechmatics |
| Gladia | Solaria |
| xAI | Grok |

ElevenLabs, Soniox, Deepgram, Speechmatics, and xAI support streaming.

Open **Configure** on a card to add and verify the key. Use cloud models when you need a
language the local models handle poorly, or accuracy beyond what your Mac can run.

### Custom models

If your provider exposes an **OpenAI-compatible transcription API**, add it under the
**Custom** filter with **Add Model**: a display name, endpoint, key, and model name.
Presets fill in the details for **Together AI**, **DeepInfra**, and **OpenRouter**.

Zerm sends a one-second test recording before saving. If the endpoint does not answer
correctly, nothing is saved and the error is shown in the form. Providers with their own
bespoke API are not supported through this path.

## Model Settings

The **Settings** button on the models screen opens the settings for the selected model.
It shows only what that model actually supports, so the list changes as you switch.

- **Output Format** — a style hint the model follows, kept separately for each language.
  Shown for models that accept a prompt, such as Whisper, OpenAI, Groq, Soniox, and
  custom endpoints.
- **Automatic text formatting** — paragraphs and capitalisation for long dictation. On by
  default.
- **Voice Activity Detection** and **Prewarm model** — for Whisper and Parakeet.
- **Show Live Text Preview** — while a streaming model is active.
- **Cloud timeout** — how long to wait for a cloud provider, from 30 seconds to 30
  minutes. The default is 60 seconds.

Your [dictionary](dictionary.html) terms are sent automatically to every model marked
**Uses Dictionary**. There is nothing to switch on.

## Choosing a model

**Disk and memory.** Each card shows the download size. Zerm marks a model **Heavy for
this Mac** when it would use a large share of your memory, and **Unavailable** when it
would not fit.

**Language.** Set the language on the models screen. Parakeet V3 and Gemini detect it
themselves, and English-only models are always English. A
[Power Mode](power-mode.html) can use a different model and language for one app.

**Intel Macs.** Local models do not run reliably on Intel hardware and Zerm says so.
Recommended picks only Whisper models there; a cloud model is usually the better choice.

## Downloading and managing

Models download in the background with progress shown, and are verified after download.
Delete one at any time to reclaim the space. Deleting the model you are using clears your
default, so pick another before you dictate again.

**Prewarm model** is on by default: shortly after launch and after your Mac wakes, the
active Whisper or Parakeet model is loaded before you press anything, so the first
dictation is not the slow one. It is skipped in Low Power Mode.

## The enhancement model is separate

If you use [enhancement](enhancement.html), that runs on a second model — on-device via
`llama.cpp`, Ollama, a local CLI, or a cloud provider. It is chosen and downloaded
separately.

On device, enhancement offers **Gemma 4 E2B** (the default) and **Qwen3 4B Instruct**.
[Read Aloud](read-aloud.html) picks its on-device model on its own screen.
