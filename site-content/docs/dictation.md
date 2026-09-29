---
title: Dictation
eyebrow: Getting started
summary: Press a key, talk, and the text lands at your cursor — plus everything that happens in between.
---

Dictation is the core loop: hold a shortcut, speak, release, and clean text appears
wherever your cursor already was. It works in every app, because Zerm inserts text the
same way you would paste it rather than integrating with anything.

## The loop

1. **Start.** Press your dictation shortcut. The recorder appears and Zerm starts
   capturing from your chosen microphone.
2. **Speak.** On a local model, transcription runs entirely on your Mac. With a
   streaming model the words appear in the recorder as you talk — see
   [models](models.html).
3. **Stop.** Release the key, press it again, or pause long enough for auto-stop to end
   it.
4. **Insert.** The text is pasted at your cursor.

Press Escape twice while the recorder is showing and the recording is discarded. The
first press shows a hint; the second, within a second and a half, cancels. Nothing is
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

When Zerm hears nothing above the level threshold for long enough, it ends the recording
for you.

- **Silence before stopping** — 2.5 seconds, long enough that a normal thinking pause
  does not cut you off mid-sentence.
- **Initial silence** — 6 seconds. If you never start speaking, the recording gives up
  rather than sitting open.
- **Minimum recording length** — 0.8 seconds, so a mis-press does not immediately
  produce an empty transcript.

These values are fixed. Auto-stop applies to toggle-style recordings; in push to talk you
are already holding the key, so releasing it is the stop.

## The recorder

Two styles, chosen in Settings:

- **Mini** — a small floating pill you can position where you like. The default.
- **Notch** — anchored to the notch on Macs that have one, out of the way of everything
  else.

Both show the level meter, the elapsed time, the active [Power Mode](power-mode.html),
the enhancement state, and the live text from a streaming model. Both offer the same
shortcuts while visible.

## Insertion

Text is placed on the clipboard and pasted with a synthetic ⌘V at the current insertion
point. That needs Accessibility permission; without it Zerm can copy but not paste. See
[permissions](permissions.html).

**Restore Clipboard After Paste** is off by default. Turn it on and Zerm puts your
previous clipboard contents back shortly after pasting — worth it if you rely on your
clipboard, at the cost of a small window where the two can race.

While it holds the clipboard, Zerm marks the entry as transient and auto-generated, so
well-behaved clipboard managers do not record your transcripts in their history.

**Use AppleScript Paste** is an alternative insertion path for the rare app where the
synthetic keystroke does not land.

**Add Space After Paste**, in Model Settings, is on by default, so consecutive
dictations do not run together.

## What happens to the text before you see it

In order, and all locally:

1. The transcript is cleaned up: filler words, if enabled, and the stray tokens speech
   models emit.
2. Automatic text formatting is applied, if on.
3. Your [dictionary](dictionary.html) replacements are applied.
4. Punctuation and lowercase rules are applied, if a [Power Mode](power-mode.html) sets
   them.
5. The result is inserted — and, depending on your
   [output mode](output-modes.html), may then be improved by a language model, with the
   same rules applied again to its output.

## Language

The language setting is what the speech model is allowed to hear.

- **Pin a language** when you will speak that language. English in a code editor,
  Hebrew in a Hebrew chat.
- **Auto** is for recordings where you actually switch languages.
- Do not pin Hebrew if you are about to speak English or Russian. The model will try
  to hear Hebrew and the transcript will be wrong.

Some models decide for themselves: Parakeet V3 and Gemini detect the language, and the
ivrit.ai models treat Auto as Hebrew while keeping English words. See
[models](models.html).

Enhancement never translates. Mixed sentences stay mixed. See
[AI enhancement](enhancement.html).

## While recording

- **Mute Audio While Recording** — on by default. Your Mac's output is silenced for the
  length of the recording, so music or a call does not leak into the microphone.
  **Keep Playing on Headphones** skips the mute when you are listening on headphones.
- **Sound Feedback** — a short cue on start and stop. On by default, and the sounds are
  replaceable.

## History

Every dictation is kept in History, under Dictation in the sidebar, until your
[retention settings](privacy-retention.html) remove it. Each row has a copy button, and
a recording whose audio is still on disk can be transcribed again with a different model.

## Audio and video files

Dictation is not the only input. [Transcribe File](transcribe-file.html) takes an
existing recording, voice memo, or video and produces a full transcript with each
speaker identified.
