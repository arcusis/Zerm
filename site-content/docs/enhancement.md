---
title: AI enhancement
eyebrow: Dictation
summary: Providers, prompts, context, and the timeout settings that decide what happens when a model is slow.
---

Enhancement takes the raw transcript and runs it through a language model before it
reaches you — fixing punctuation, structure, and the words a speech model reliably
mishears. It is off by default. Zerm dictates perfectly well without it.

![Enhancement settings](img/enhancement.png)

## Providers

Enhancement is provider-agnostic. Whatever you pick, the transcript and the active
prompt are what get sent, and nothing else leaves your Mac unless you switch context
options on.

**On device.** The bundled local model runs through `llama.cpp` with no network access
at all. It is the only provider that keeps enhancement entirely offline.

**Ollama.** Points at a local Ollama server, so the model still runs on your own
hardware — useful if you already keep models there.

**Local CLI.** Shells out to a command-line tool you nominate. For anything you host
yourself that has no HTTP API worth wiring up.

**Cloud.** Anthropic, OpenAI, Gemini, Groq, Cerebras, OpenRouter, and Mistral are
configured with an API key. A **Custom** option accepts any OpenAI-compatible chat
completions endpoint.

No provider is contacted until you add a key and select it. If a key stops validating,
enhancement switches itself off rather than failing silently on every recording.

## Prompts

A prompt is the instruction the model gets alongside your transcript. Zerm ships with a
set of predefined prompts and you can add your own; each has a title, the instruction
text, and an icon.

The active prompt is what runs. Switch it from the recorder with ⌘1 through ⌘0 — see
[enhancement shortcuts](enhancement-shortcuts.html) — or pin a prompt to a
[Power Mode](power-mode.html) so it changes with the app you are in.

### Trigger words

A prompt can carry trigger words. If a transcript begins with one, Zerm strips it,
switches to that prompt, turns enhancement on for that one recording, and restores your
previous settings afterwards. Saying "summarise, here are my notes from the standup…"
can select the summarising prompt without touching the interface.

Trigger-word detection is a separate setting from enhancement itself.

## Context

By default the model sees the transcript and nothing else. Three optional context
sources can be added; each is its own switch.

**Selected text.** Whatever is highlighted in the frontmost app is included, so
instructions like "rewrite this properly" have something to act on. Needs Accessibility
permission.

**Clipboard.** The current clipboard contents are included. Useful when you are
dictating a reply to something you just copied.

**Screen.** On-screen text is captured and included. Needs Screen Recording permission.

The details of what is captured, when, and what is kept are on the
[contextual awareness](contextual-awareness.html) page. Your
[dictionary](dictionary.html) vocabulary is also passed along as spelling guidance
whenever enhancement runs.

## Skipping short transcriptions

"Yes", "thanks", and "on my way" do not benefit from a language model, and sending them
adds latency for nothing. **Skip short transcriptions** is on by default and bypasses
enhancement whenever the transcript is at or under the word threshold, which defaults to
three words and is adjustable from one to fifteen.

A transcript that matched a trigger word is enhanced regardless of length — you asked
for it explicitly.

## Timeouts and retries

**Timeout duration** bounds how long Zerm waits for the model, from 3 to 60 seconds. The
default is 15. It applies to Enhanced mode, where you are sitting there waiting; Refine
runs after the paste has already happened and uses its own, much shorter budget.

**On timeout** decides what happens when the budget runs out: *Retry* (the default) or
*Fail immediately*. Either way you end up with the raw transcript rather than nothing —
a slow model costs you the improvement, never the words.

Network errors, server errors, and rate limits are retried up to three times with
exponential backoff, independently of the timeout setting.

## When enhancement does not run

Enhancement is skipped, quietly and by design, when:

- The output mode is **Instant**. No model is involved in that mode at all.
- The transcript is at or under the short-transcription threshold.
- No provider is configured, or its key stopped validating.
- The active [Power Mode](power-mode.html) has enhancement switched off.

If enhancement looks like it is not running, that list is the place to start.
