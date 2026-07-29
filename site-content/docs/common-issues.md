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
keystrokes. Turn on **AppleScript paste** in Settings, which uses a different insertion
path.

**Text goes to the wrong place.** Zerm pastes at whatever had focus when the recording
started. If you clicked elsewhere mid-recording, that is where it lands.

**Nothing at all, and no error.** Check whether the recording was cancelled — Escape
during a recording discards it silently by design.

## Refined text is not replacing what was typed

Expected in Electron apps (Slack, VS Code, Cursor, Discord, Notion), in browser web
content, and in terminals. Those applications do not support the accessibility writes
that in-place replacement needs, so Zerm offers the refined text instead of changing
what you already have. This is documented behaviour, not a fault — see
[output modes](output-modes.html).

If you want final text on the first paste in those apps, use **Enhanced** mode.

## The recording stops while I am still talking

Auto-stop on silence is ending it. Two causes:

- **Your pauses are longer than the threshold.** Increase the silence duration in
  Settings.
- **Your microphone level is too low** for the level threshold to register as speech.
  Raise the input gain in System Settings → Sound, or test it in Zerm's microphone
  test. See [audio input](audio-input.html).

You can also turn auto-stop off entirely and stop recordings yourself.

## Recording does not start

- **Check the microphone permission** in System Settings → Privacy & Security →
  Microphone.
- **Check the shortcut is still bound.** Another app may have claimed the same key.
  Try a different modifier.
- **If it is bound to Fn**, note that Fn plus any other key cancels the trigger, which
  is intentional so your function row keeps working.
- **Zerm ignores triggers while it is busy** transcribing, enhancing, or speaking. Wait
  for the current one to finish.

## Enhancement is not running

Go through these in order:

1. The [output mode](output-modes.html) is **Instant**, which never calls a model.
2. The transcript was at or under the **skip-short-transcriptions** threshold — three
   words by default.
3. No provider is configured, or its API key stopped validating. Zerm switches
   enhancement off when a key fails rather than erroring on every recording.
4. The active [Power Mode](power-mode.html) has enhancement switched off for this app
   or website.

## Enhancement is slow, or times out

Raise the **timeout duration** in enhancement settings — 15 seconds is the default and a
large cloud model on a slow connection can need more. Set **On timeout** to *Retry*.

A timeout never costs you the words: you get the raw transcript.

For consistently low latency, use the on-device provider or a small hosted model.

## Power Mode is not switching

**Application triggers** match on bundle identifier, exactly. A different build of the
same app is a different identifier — remove and re-add it from the app picker.

**Website triggers** need Automation permission for that specific browser. macOS asks
once per browser; if you declined, re-enable Zerm under System Settings → Privacy &
Security → Automation.

**Matching is a substring match on a cleaned URL**, which catches more than people
expect. A short trigger like `mail` matches a great many pages. See
[Power Mode](power-mode.html).

**Order matters.** The first enabled mode that matches wins. Move the specific mode
above the general one.

## Transcription accuracy is poor

- **Use a larger model.** Large v3 Turbo (Quantized) is the best accuracy-per-megabyte
  in the list. See [models](models.html).
- **Set the language explicitly** if you always dictate the same one. Automatic
  detection occasionally guesses wrong on short recordings.
- **Add the words it gets wrong** to your [dictionary](dictionary.html).
- **Check your microphone**, not the model. A laptop mic across a room is the usual
  culprit.
- **Try turning echo cancellation off** if you enabled it. It changes the audio
  character and can cost accuracy in a quiet room.

## Local models will not run

On **Intel Macs**, local models do not run reliably and Zerm says so. Use Apple Speech
or a cloud provider.

Apple Speech requires **macOS 26**.

If a model download failed partway, delete it and download again.

## Read Aloud says nothing

- The **Read Aloud hotkey is unset by default.** Assign one.
- Reading the selection needs **Accessibility permission**.
- A cloud voice needs a valid API key; the bundled Kokoro voice needs its model
  downloaded.

See [read aloud](read-aloud.html).

## History is empty, or emptier than expected

Transcript auto-delete is probably on. With the retention period at zero, each
transcript is deleted the moment it completes.

Audio auto-delete is a **different setting** and removes only the audio, keeping the
text. See [privacy and retention](privacy-retention.html).

## My statistics changed unexpectedly

Usage statistics live in their own store and are not affected by deleting transcripts.
If your totals moved, it was not history cleanup.

Two things do change them. **Reset Statistics** in Privacy settings clears them
permanently, and it cannot be undone. And the upgrade to this version backfills your
history from the transcripts that still exist — if earlier retention had already deleted
them, those sessions cannot be counted retrospectively.

If your statistics are empty after a reset, that is final: keeping transcripts will not
bring them back. See [privacy and retention](privacy-retention.html).

## Reporting something else

Enable **debug logging** in Settings, reproduce the problem, then export the logs. Open
an issue at [github.com/arcusis/Zerm/issues](https://github.com/arcusis/Zerm/issues)
with:

- What you did, what you expected, and what happened instead.
- Your macOS version and Mac model.
- The model and provider you were using.
- The exported log, and a short screen recording if the problem is visual.

A screen recording is worth more than any description. Please check the logs for
anything you would rather not share before attaching them.
