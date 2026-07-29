---
title: Contextual awareness
eyebrow: Privacy
summary: The three optional context sources — selected text, clipboard, and screen — and exactly what each one sends.
---

An [enhancement](enhancement.html) prompt does better work when it knows what you are
writing about. Zerm can supply three kinds of context, each optional and each off unless
you switch it on.

None of them apply when your [output mode](output-modes.html) is Instant, because no
model runs at all in that mode.

![Context settings](img/contextual-awareness.png)

## Selected text

Whatever is highlighted in the frontmost application is passed to the model alongside
your transcript.

This is what makes instructions work. Select a paragraph, dictate "make this shorter and
drop the second sentence", and the model has the paragraph to act on.

Requires Accessibility permission. Without it, nothing is read and the transcript goes
to the model alone.

## Clipboard context

The current contents of your clipboard are passed to the model.

Useful when you have just copied the thing you are replying to. Off by default.

The clipboard is read at the moment the recording starts, and the captured value is
cleared once the enhancement finishes.

## Screen context

Text visible on your screen is captured and passed to the model.

This is the broadest of the three, and the one to think about before enabling. It reads
what is on screen rather than what you selected, which means it may include whatever
else happens to be visible.

**How it works:** Zerm captures the screen, extracts text from the image, and includes
that text in the prompt. What is sent to the model is text, not the image.

**What is kept:** nothing. The extracted text is held only for the duration of the
enhancement and then cleared. It is not written to disk and not saved to history.

**Permission:** requires Screen Recording. macOS often needs Zerm fully quit and
reopened before a fresh grant takes effect — see [permissions](permissions.html).

Screen context is also per-[Power Mode](power-mode.html), so you can enable it only for
the apps where it earns its keep and leave it off everywhere else.

## Where the context goes

Context is added to the system message sent to your enhancement provider, in labelled
sections alongside the transcript. That means:

- With the **on-device** provider, context never leaves your Mac.
- With **Ollama** or a **local CLI**, it goes to whatever you are running locally.
- With a **cloud provider**, it goes to that provider along with the transcript.

If you enable screen context, know which provider you are pointing it at.

## Vocabulary

Your [dictionary](dictionary.html) vocabulary is also included whenever enhancement
runs, as spelling guidance. It is a fixed list you wrote yourself, not captured content,
and it has no permission or switch of its own.

## Turning it all off

Set the output mode to **Instant**. No context is gathered, no model is called, and the
transcript goes straight to your cursor.
