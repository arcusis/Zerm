---
title: Models
eyebrow: Setup
summary: Which transcription model to use, what each one costs you in speed, size and memory, and how local and cloud differ.
---

Zerm separates the model that turns speech into text from the model that improves that
text afterwards. This page covers the first one. For the second, see
[AI enhancement](enhancement.html).

![The model list](img/models.png)

## Local models

Local models download once and then run entirely on your Mac, with Metal acceleration.
No key, no account, no network — dictation keeps working on a plane.

### Whisper

The default family, running on `whisper.cpp`.

| Model | Size | Notes |
| --- | --- | --- |
| Tiny | 75 MB | Fastest, least accurate. Fine for short commands. |
| Tiny (English) | 75 MB | Same, English only, slightly more accurate on it. |
| Base | 142 MB | The smallest one worth using for real dictation. |
| Base (English) | 142 MB | English-only Base. |
| Small | 466 MB | A solid everyday speed/accuracy balance. |
| Small (English) | 466 MB | English-only Small. |
| Large v3 Turbo | 1.5 GB | The most accurate. Around 1.8 GB of memory in use. |
| Large v3 Turbo (Quantized) | 547 MB | Nearly the same accuracy for a third of the disk. |

If you are not sure: **Large v3 Turbo (Quantized)**. It is the best accuracy-per-megabyte
in the list, and on Apple Silicon it is fast enough that you will not notice the
difference against Small.

The `.en` variants only handle English, and are marginally better at it than the
multilingual model of the same size. Take one only if you never dictate anything else.

You can also import your own fine-tuned Whisper model — see
[custom local models](custom-local-whisper-models.html).

### Parakeet

NVIDIA's Parakeet, running through FluidAudio. Both variants are around half a gigabyte
and noticeably faster than Whisper at comparable accuracy, and both support streaming.

- **Parakeet V2** — English only.
- **Parakeet V3** — English plus 25 European languages.

Worth trying if Whisper Large feels slow on your machine.

### Apple Speech

The transcription built into macOS, used through the Speech framework. Nothing to
download, and it is the lightest option on memory. **Requires macOS 26.**

## Cloud models

Cloud models send your audio to a provider. Nothing is contacted until you add a key and
select the model, and you can keep local and cloud models installed side by side and
switch per [Power Mode](power-mode.html).

Providers: Groq, OpenAI, Deepgram, ElevenLabs, Gemini, Mistral, Soniox, Speechmatics,
xAI, and AssemblyAI. Several of them also support streaming, where text starts appearing
before you stop talking.

Use them when you need a language the local models handle poorly, or accuracy beyond
what Large v3 Turbo gives you. Everything else about the app works identically.

### Custom models

If your provider exposes an **OpenAI-compatible transcription API**, add it yourself
with a base URL, key, and model name. Nothing else is supported through this path — a
provider with its own bespoke API needs its own integration.

## Choosing a model

**Disk and memory.** Each model card shows the download size and roughly how much memory
it wants. Zerm warns you before you pick something your Mac cannot comfortably hold.

**Language.** Multilingual models list which languages they support. Language is set
globally and can be overridden per Power Mode; leave it on automatic if you switch
often.

**Intel Macs.** Local models do not run reliably on Intel hardware and Zerm says so in
the interface. On an Intel Mac, use Apple Speech or a cloud provider.

## Downloading and managing

Models download in the background with progress shown, and are verified after download.
Delete one at any time to reclaim the space; deleting the model you are currently using
prompts you to choose another first.

**Prewarm on wake** is on by default: after your Mac wakes, the active model is loaded
before you press anything, so the first dictation of the day is not the slow one.

## The enhancement model is separate

If you turn on [enhancement](enhancement.html), that runs on a second model —
on-device via `llama.cpp`, Ollama, a local CLI, or a cloud provider. It is chosen
separately and downloaded separately.

Zerm uses three different on-device jobs, and they do not share a default model.

**Dictation** is Whisper (or another speech model). That path is already instant.
It is configured under Dictation Models.

**Enhancement** cleans the transcript after dictation. Instant + Refine defaults
to **Qwen3 1.7B** (~1.11 GB): multilingual, follows “clean the line, do not
chat,” small enough to stay warm. **Qwen3 0.6B** is the speed opt-in. **Qwen3
4B** is the quality opt-in. Gemma 4 is not offered here — it introduces itself
as a Google DeepMind model instead of rewriting the line.

**Read Aloud** keeps **Gemma 4 E2B**. Retell can wait. Larger Gemma models stay
opt-in on that screen only.

Phi-4 Mini and Llama 3.2 were considered and not catalogued: Phi is a reasoner
(slow, chatty), Llama 3.2 is weak on Hebrew and mixed speech.

Read Aloud uses a third model again. See [read aloud](read-aloud.html).
