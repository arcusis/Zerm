---
title: Common issues
eyebrow: Support
summary: The problems that come up most, and what actually fixes them.
---

Work down the section that matches your symptom. If none of it helps, the last section
covers what to send us.

## Text is not appearing at my cursor

**The transcript is on the clipboard instead.** Accessibility permission is not
granted, or macOS has not noticed that it is. Grant it, then quit Zerm completely with
⌘Q and reopen — closing the window is not quitting. See
[permissions](permissions.html).

**It works in some apps and not others.** A few applications reject synthetic
keystrokes. Turn on **Use AppleScript Paste** in Settings, which uses a different
insertion path.

**Text goes to the wrong place.** Zerm pastes at whatever has focus when the text is
ready. If you clicked elsewhere mid-recording, that is where it lands.

**Nothing at all, and no error.** Check whether the recording was cancelled — pressing
Escape twice while the recorder is showing discards it by design.

## Refined text is not replacing what was typed

Expected in Electron apps (Slack, VS Code, Cursor, Discord, Notion), in browser web
content, and in terminals. Those applications do not support the accessibility writes
that in-place replacement needs, so Zerm offers the refined text instead of changing
what you already have. This is documented behaviour, not a fault — see
[output modes](output-modes.html).

If you want final text on the first paste in those apps, use **Enhanced**, globally or in
a [Power Mode](power-mode.html) for those apps.

## The recording stops while I am still talking

Auto-stop on silence is ending a toggle-style recording. The usual cause is a microphone
level too low for your speech to register over the threshold. Raise the input gain in
System Settings → Sound, and check the level in Zerm's microphone test. See
[audio input](audio-input.html).

If you pause for long stretches, use push to talk: releasing the key is then the only
thing that stops the recording.

## Recording does not start

- **Check the microphone permission** in System Settings → Privacy & Security →
  Microphone.
- **Check the shortcut is still bound.** Another app may have claimed the same key.
  Try a different modifier.
- **If it is bound to Fn**, note that Fn plus any other key cancels the trigger, which
  is intentional so your function row keeps working.
- **Zerm ignores triggers while it is busy** transcribing, enhancing, or speaking. Wait
  for the current one to finish.
- **The model is not downloaded.** After an update that retired your model, the Default
  Model card on the Models screen asks you to download its replacement. See
  [models](models.html).

## My model changed after updating

Zerm 2.8.6 retired Whisper Tiny, Base, and Small and Parakeet V2, and moved anyone using
one to its replacement — Parakeet Unified or Large v3 Turbo (Quantized) — including in
Power Modes. Download the replacement, or pick another model under **Recommended**. See
[models](models.html).

## Meetings is gone

Meetings was removed in Zerm 2.8.6 and replaced by
[Transcribe File](transcribe-file.html), which transcribes recordings with each speaker
identified. Meeting recordings from earlier versions were permanently deleted when 2.8.6
first opened and cannot be recovered.

## Enhancement is not running

Zerm shows a notification when it skips or fails an enhancement, with the reason. If you
saw none, go through these in order:

1. The **Output** is **Instant**, which never calls a model. Check both the Enhancement
   page and the active [Power Mode](power-mode.html) for this app or website.
2. The transcript was at or under the **Skip short transcriptions** threshold — three
   words by default.

If you did get a notification:

- **Enhancement skipped** — the provider is not set up. Download the on-device model,
  add or fix the API key, choose a model, or check the server address. The notification
  opens Enhancement settings for you.
- **Enhancement failed** — the provider could not be reached or returned an error.
  For Ollama, check that the server is running.
- **Enhancement discarded** — the model changed the language or the length too much.
  See the next section.

Your original text is kept in every case. See [AI enhancement](enhancement.html).

## The text came out in the wrong language

**Everything became Hebrew, or Hebrew appeared in English or Russian speech.** Set
the dictation language to the language you are actually speaking. A Power Mode pinned
to Hebrew will force Hebrew on every utterance, including English. The ivrit.ai models
treat Auto as Hebrew; choose English on them for English-only dictation.

Enhancement is not allowed to translate. Mixed Hebrew and English stays mixed. If a
model still returns a different writing system, Zerm keeps the raw transcript and tells
you it discarded the rewrite. A prompt meant to translate needs **May change language or
length** turned on.

**A Power Mode is not English and the result is broken.** That mode's language setting
is what the speech model hears. Pin English for English-only apps, Hebrew only when you
will speak Hebrew there, and Auto only when you actually switch languages in that app —
or leave it on **Use global setting**.

## Enhancement is slow, or times out

Raise the **Timeout duration** in Enhancement settings — 15 seconds is the default and a
large cloud model on a slow connection can need more. Set **On timeout** to *Retry*.

A timeout never costs you the words: you get the raw transcript, and a notification
says it timed out.

Instant + Refine pastes the raw text first, so a slow model cannot block the
cursor. If you are in Enhanced mode, you are waiting on purpose.

For consistently low latency, use a small hosted model or a fast provider.

## Power Mode is not switching

**Application triggers** match on bundle identifier, exactly. A different build of the
same app is a different identifier — remove and re-add it from the app picker.

**Website triggers** need Automation permission for that specific browser. macOS asks
once per browser; if you declined, re-enable Zerm under System Settings → Privacy &
Security → Automation. Firefox and Zen are not supported.

**The browser answered too late.** Zerm waits at most half a second for the tab's URL.
A browser that is busy falls back to application triggers for that recording.

**Matching is a substring match on a cleaned URL**, which catches more than people
expect. A short trigger like `mail` matches a great many pages. See
[Power Mode](power-mode.html).

**Order matters.** The first enabled mode that matches wins. Move the specific mode
above the general one.

## A Power Mode changed my global settings

It no longer can. Since Zerm 2.8.6 a Power Mode applies its choices only to dictations in
its own apps and websites, and every setting you have not changed shows **Use global
setting**. If a mode still uses a model or prompt you do not want, open it and set that
field back to **Use global setting**.

## Transcription accuracy is poor

- **Use the recommended model.** The **Recommended** filter on the Models screen picks
  the best English, multilingual, and Hebrew models for your Mac. See
  [models](models.html).
- **For Hebrew, use an ivrit.ai model**, or a cloud model marked **Great in Hebrew**.
- **Set the language explicitly** if you always dictate the same one. Automatic
  detection occasionally guesses wrong on short recordings.
- **Add the words it gets wrong** to your [dictionary](dictionary.html).
- **Check your microphone**, not the model. A laptop mic across a room is the usual
  culprit.
- **Try turning Echo Cancel / AGC off** if you enabled it. It changes the audio
  character and can cost accuracy in a quiet room.

## Transcribe File problems

- **"Completed without speakers."** Speaker identification could not run, usually
  because its model could not download. Check your connection and retry the file.
- **The model is not downloaded, or needs an API key.** The Model picker in Options lists
  only models you can use; download one or add a key on the Models screen.
- **"This file type is not supported."** Zerm needs an audio or video file. Convert
  anything else first.
- **The queue is empty after relaunching.** The queue is not kept between launches.
  Finished transcripts are in History — use **Open Transcript**.

See [Transcribe File](transcribe-file.html).

## Local models will not run

On **Intel Macs**, local models do not run reliably and Zerm says so. Use a cloud model.

Parakeet models need Apple Silicon. Apple Speech requires **macOS 26**.

If a model download failed partway, delete it and download again.

## Read Aloud says nothing

- The **Read Aloud trigger key is unset by default.** Assign one, and check **Enable Read
  Aloud** is on.
- Reading the selection needs **Accessibility permission**.
- A cloud voice needs a valid API key; the Kokoro voice needs its model downloaded.
- **The text is not English** and no Apple voice for that language is installed. Kokoro
  and Deepgram speak English only; install a voice in System Settings.

See [read aloud](read-aloud.html).

## History is empty, or emptier than expected

**Auto-delete Transcripts** is probably on. Set to Immediately, each transcript is
deleted the moment it completes.

**Auto-delete Audio Files** is a **different setting** and removes only the audio,
keeping the text. See [privacy and retention](privacy-retention.html).

## My statistics changed unexpectedly

Usage statistics live in their own store and are not affected by deleting transcripts.
If your totals moved, it was not history cleanup.

Check the Dashboard range first: totals and time saved follow the range you select, so
**7 Days** shows far less than **All Time**.

**Reset Statistics** clears them permanently, and it cannot be undone. Keeping
transcripts will not bring them back. See [privacy and retention](privacy-retention.html).

## Reporting something else

Turn on **Debug Logging** in Settings → Advanced, reproduce the problem, then use
**Export Logs**. Open an issue at
[github.com/arcusis/Zerm/issues](https://github.com/arcusis/Zerm/issues) with:

- What you did, what you expected, and what happened instead.
- Your Zerm version, macOS version, and Mac model.
- The model and provider you were using.
- The exported log, and a short screen recording if the problem is visual.

A screen recording is worth more than any description. Please check the logs for
anything you would rather not share before attaching them.
