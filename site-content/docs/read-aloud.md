---
title: Read aloud
eyebrow: Speech
summary: Select any text on your Mac and hear it back — with the markup, code and symbols cleaned up first.
---

Read Aloud is the other half of the app. Highlight text anywhere in macOS, press your
Read Aloud key, and Zerm speaks it. Press again to stop.

It lives under **Read Aloud** in the sidebar: **Speak** for the settings, **History** for
what you have listened to, and **Models & Voices** for the downloads.

## The trigger

Read Aloud gets its own **Trigger key**, configured the same way as the dictation one: a
modifier key on its own, or a custom combination you record. It is unset until you
choose one, and **Enable Read Aloud** switches the whole feature off without losing the
setting.

Reading whatever is selected needs Accessibility permission — the same permission
dictation uses to paste. See [permissions](permissions.html).

## Smart text cleanup

Raw text is usually not speakable text. Documentation is full of markup, code spans,
URLs, and symbols that a voice will happily read out character by character.

**Smart text cleanup** is on by default and cleans the text before it reaches the voice,
offline and instantly:

- Acronyms and units are expanded the way a person would say them.
- URLs, file paths, code blocks, and tables are read the way a person would say them
  rather than spelled out.
- Markdown syntax and emoji are dropped.
- Section markers, symbols, and status codes are turned into words.

So `See §4.2 — the POST /v1/ingest endpoint returns 202 ✅` is read as "See section four
point two — the ingest endpoint returns a two oh two accepted."

Turn it off if you want the text read literally.

## Reading mode

**Reading mode** decides whether the on-device language model rewrites the selection
before it is spoken:

| Mode | What you hear |
| --- | --- |
| Read exactly | The selection, with no AI rewriting. The default. |
| Retell | The selection retold naturally, without losing its meaning. |
| Summarize | A shorter version with the important points. |
| Explain | The selection explained, with enough context to understand it. |
| Simplify | Difficult language rewritten in simpler terms. |

The AI modes run entirely on your Mac and need an on-device model downloaded. They add a
moment before playback starts. If the model cannot produce a result, Zerm reads the
exact text instead and tells you.

Retell keeps the source writing system. A Hebrew selection stays Hebrew. A mixed
Hebrew/English selection is not rewritten as all-Hebrew.

## Voices

**Kokoro** is the local voice, running on `sherpa-onnx`. It downloads once and then
works offline, and it is good enough to listen to a long document without fatigue.

**Apple System** uses the voices already on the Mac, including Hebrew ones if you have
installed them.

**Cloud voices** — Deepgram, Inworld, ElevenLabs, Gemini, OpenAI, and Cartesia — are
available if you add a key. They send the text you are reading to that provider. Kokoro
and Apple System send nothing anywhere.

Each provider keeps its own voice selection, so switching provider and switching back
does not lose your choice. **Preview voice** plays a sample before you rely on it.

### Other languages

Kokoro and Deepgram speak English only. When the selection is in another language, Zerm
reads it with the best installed Apple voice for that language and says so. If no
matching Apple voice is installed, Zerm asks you to install one in System Settings.

## Playback

**Speed** runs from 0.5× to 2×, defaulting to 1×. It applies to every provider.

Reading is interruptible: pressing the key again stops playback immediately. Starting a
dictation while Zerm is speaking is blocked rather than overlapped — one voice at a
time.

## History and statistics

Read Aloud History keeps your most recent 500 sessions on your Mac: the selected text,
what was spoken, and the voice used. Delete entries one at a time or clear the list.

Words read and sessions completed are also counted for the dashboard. Those are counters
only, with no text in them. See [privacy and retention](privacy-retention.html).
