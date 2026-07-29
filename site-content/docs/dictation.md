---
title: Dictation
eyebrow: Getting started
summary: Press a key, talk, and the text lands at your cursor — plus everything that happens in between.
---

Dictation is the core loop: hold a shortcut, speak, release, and clean text appears
wherever your cursor already was. It works in every app, because Zerm inserts text the
same way you would paste it rather than integrating with anything.

![The recorder during dictation](img/dictation.png)

## The loop

1. **Start.** Press your dictation shortcut. The recorder appears and Zerm starts
   capturing from your chosen microphone.
2. **Speak.** Transcription runs while you talk. On a local model this is entirely on
   your Mac.
3. **Stop.** Release the key, press it again, or say nothing for a couple of seconds and
   let auto-stop end it.
4. **Insert.** The text is pasted at your cursor.

Press Escape at any point before insertion and the recording is discarded. Nothing is
written and nothing is saved to history.

## Trigger styles

Each shortcut has a mode that decides what pressing it means:

- **Push to talk** — record while held, stop on release. The most predictable, and the
  best default for short dictation.
- **Toggle** — press to start, press again to stop. Better for anything long, since you
  are not holding a key for two minutes.
- **Hybrid** — a quick tap toggles; holding the key past half a second becomes push to
  talk. You get both without deciding in advance.

You can configure two independent dictation shortcuts, each with its own mode, so push
to talk and toggle can live on different keys. See [shortcuts](shortcuts.html) for the
full list.

## Auto-stop on silence

Auto-stop is on by default. When Zerm hears nothing above the level threshold for long
enough, it ends the recording for you.

- **Silence before stopping** — 2.5 seconds by default. This was raised from a much
  shorter value because a normal thinking pause in long-form dictation was tripping it
  and cutting people off mid-sentence.
- **Initial silence** — 6 seconds. If you never start speaking, the recording gives up
  rather than sitting open.
- **Minimum recording length** — 0.8 seconds, so a mis-press does not immediately
  produce an empty transcript.

Auto-stop applies to toggle-style recordings. In push to talk you are already holding
the key, so releasing it is the stop.

## The recorder

Two styles, chosen in Settings:

- **Mini** — a small floating pill you can position where you like.
- **Notch** — anchored to the notch on Macs that have one, out of the way of everything
  else.

Both show the level meter, the elapsed time, the active [Power Mode](power-mode.html),
and the enhancement state. Both offer the same shortcuts while visible.

## Insertion

Text is placed on the clipboard and pasted with a synthetic ⌘V at the current insertion
point. That needs Accessibility permission; without it Zerm can copy but not paste. See
[permissions](permissions.html).

**Restore clipboard after paste** is off by default. Turn it on and Zerm puts your
previous clipboard contents back a couple of seconds after pasting — worth it if you
rely on your clipboard, at the cost of a small window where the two can race.

While it holds the clipboard, Zerm marks the entry as transient and auto-generated, so
well-behaved clipboard managers do not record your transcripts in their history.

**AppleScript paste** is an alternative insertion path for the rare app where the
synthetic keystroke does not land.

**Append trailing space** is on by default, so consecutive dictations do not run
together.

## What happens to the text before you see it

In order, and all locally:

1. Formatting from the transcription model is normalised.
2. Filler words are removed, if enabled.
3. Your [dictionary](dictionary.html) replacements are applied.
4. Per-mode punctuation and lowercase rules are applied.
5. The result is inserted — and, depending on your
   [output mode](output-modes.html), may then be improved by a language model.

## While recording

- **Pause media** — playing audio is paused when recording starts and resumed
  afterwards, with a configurable delay. Off by default.
- **Mute system audio** — on by default, so system sounds do not end up in the
  recording.
- **Sound feedback** — a short cue on start and stop. On by default, and the sounds are
  replaceable.

## Audio files

Dictation is not the only input. Drop an existing recording or voice memo into Zerm and
it runs through the same pipeline, with the same models and the same post-processing.
