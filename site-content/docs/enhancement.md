---
title: AI enhancement
eyebrow: Dictation
summary: Providers, prompts, context, and the timeout settings that decide what happens when a model is slow.
---

Enhancement takes the raw transcript and runs it through a language model —
fixing punctuation, structure, and the words a speech model reliably mishears.

Whether it runs is decided by one setting: **Output**, at the top of the Enhancement
page. Instant never uses AI; [Instant + Refine and Enhanced](output-modes.html) do.
Zerm dictates perfectly well on Instant.

Each dictation is enhanced with exactly the prompt, provider, model, and context it
started with. Editing settings while a dictation is being processed does not change it;
the [recorder shortcuts](enhancement-shortcuts.html) are how you change the one in
progress.

## Providers

Enhancement is provider-agnostic. Whatever you pick, the transcript and the active
prompt are what get sent, and nothing else leaves your Mac unless you switch context
options on.

**On-Device.** A local model runs through `llama.cpp` with no network access at all:
**Gemma 4 E2B** by default, or **Qwen3 4B Instruct** as a smaller option. It is the only
provider that keeps enhancement entirely offline.

**Ollama.** Points at a local Ollama server, so the model still runs on your own
hardware — useful if you already keep models there.

**Local CLI.** Shells out to a command-line tool you nominate. For anything you host
yourself that has no HTTP API worth wiring up.

**Cloud.** Cerebras, Groq, Gemini, Anthropic, OpenAI, OpenRouter, and Mistral are
configured with an API key. A **Custom** option accepts any OpenAI-compatible chat
completions endpoint.

No provider is contacted until you add a key and select it. A key is verified when you
add it, and is not saved if verification fails. Providers that only transcribe speech
are not offered here.

## Prompts

A prompt is the instruction the model gets alongside your transcript. Zerm ships with
**Default**, **Assistant**, **Coding**, and **Chat**, and you can add your own from
templates or from scratch.

The active prompt is what runs. Switch it from the recorder with ⌘1 through ⌘0 — see
[enhancement shortcuts](enhancement-shortcuts.html) — or pin a prompt to a
[Power Mode](power-mode.html) so it changes with the app you are in.

### A provider and model per prompt

A prompt can use its own **AI Provider** and **AI Model** instead of the global ones. A
quick cleanup prompt can stay on the on-device model while a long rewrite uses a larger
cloud model. When both set one, a Power Mode's choice wins over the prompt's.

### May change language or length

Enhancement is normally not allowed to translate or to balloon your text; see
the language section below. A prompt whose job is exactly that — translating,
expanding notes into an email — can turn on **May change language or length**, and those
checks are skipped for it. The built-in Assistant prompt has it on.

### Trigger words

The prompt editor has a **Trigger Words** field. Trigger-word switching is currently
turned off, so starting a dictation with a trigger word does not change the prompt.

## Context

By default the model sees the transcript and nothing else. Two optional context sources
can be added in Enhancement settings; each is its own switch.

**Clipboard Context.** The clipboard is read when the recording starts, not when the
model runs. Useful when you are dictating a reply to something you just copied. Used by
both Instant + Refine and Enhanced.

**Screen Context.** On-screen text is captured and included. Needs Screen Recording
permission. Used only in **Enhanced**: Instant + Refine has already pasted by the time
the screen could be read.

The details of what is captured, when, and what is kept are on the
[contextual awareness](contextual-awareness.html) page. Your
[dictionary](dictionary.html) vocabulary is also passed along as spelling guidance
whenever enhancement runs.

## Language

Enhancement cleans the transcript. It does not translate it.

Mixed-language dictation stays mixed. Hebrew stays Hebrew, English stays English,
Russian stays Russian. Zerm discards a rewrite and keeps your original text when the
model:

- returns a different writing system than you spoke,
- grows the text far beyond what you said, or
- starts talking about itself instead of rewriting.

Prompts with **May change language or length** are exempt.

If you always speak one language in an app, pin that language on the
[Power Mode](power-mode.html) rather than leaving Auto. Pinning Hebrew when you are
about to speak English will make the speech model hear everything as Hebrew.

## Skipping short transcriptions

"Yes", "thanks", and "on my way" do not benefit from a language model, and sending them
adds latency for nothing. **Skip short transcriptions** is on by default and bypasses
enhancement whenever the transcript is at or under **Minimum words**, which defaults to
three and is adjustable from one to fifteen.

## Timeouts and retries

**Timeout duration** bounds how long Enhanced output waits for the model, from 3 to 60
seconds. The default is 15. Instant + Refine runs after the paste has already happened
and uses its own, much shorter limit.

**On timeout** decides what happens when the time runs out: *Retry* (the default), up to
three attempts, or *Fail immediately*. Either way you end up with the raw transcript
rather than nothing — a slow model costs you the improvement, never the words.

Network errors, server errors, and rate limits are retried with a short backoff.

## When enhancement does not run

Zerm tells you when it cannot enhance, instead of silently pasting the raw text. A
notification explains what happened, and your original text is always kept:

- **Skipped** — the provider is not set up: a model is not downloaded, an API key or
  model is missing, or a server address is wrong. The notification links straight to
  Enhancement settings, and appears once per launch.
- **Failed** — the provider could not be reached, returned nothing, hit a rate limit, or
  had a server error.
- **Timed out** — the timeout ran out.
- **Discarded** — the model changed the language or the wording too much.

Enhancement is skipped without a notification when:

- The output is **Instant**, globally or in the active [Power Mode](power-mode.html).
- The transcript is at or under the short-transcription threshold.
