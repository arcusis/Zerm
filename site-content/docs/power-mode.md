---
title: Power Mode
eyebrow: Context
summary: Change dictation settings automatically for the app you are in — or the website you are on — without touching your global settings.
---

A Power Mode is a named set of dictation settings that applies when you are somewhere
specific. Writing in Mail should not use the same prompt as dictating a commit message
into a terminal, and Power Mode is how Zerm stops you switching those by hand.

## Global settings stay in charge

Every setting in a Power Mode starts as **Use global setting**. A mode changes only what
you explicitly choose, and everything else follows your global settings — including when
you change them later.

A choice you make in a mode applies only to dictations in that mode's apps and websites.
It never changes your global settings, and nothing carries over after the recording. The
settings are decided once, when a recording starts, and stay fixed for that recording.

## What triggers a mode

Every mode can list applications, websites, or both. When you start a recording, Zerm
resolves which mode applies in a fixed order:

1. **Shortcut.** If you started the recording with a mode's own shortcut, that mode
   applies.
2. **Website.** If the frontmost app is a supported browser, Zerm reads the URL of the
   active tab and looks for a mode whose website list matches it.
3. **Application.** Otherwise — or if no website matched — Zerm looks for a mode whose
   application list contains the frontmost app.
4. **Default.** If neither matched, the mode marked as default applies.

Disabled modes are skipped. Where two enabled modes could both match, the first one in
the list wins, so move the more specific mode above the general one.

### Application triggers

Applications match on bundle identifier, exactly. You pick them from a list of installed
apps rather than typing a name, so there is nothing to get wrong — but it also means a
mode attached to Visual Studio Code will not fire for a different build of the same
editor.

### Website triggers — how matching really works

This is the part the interface does not spell out, and it surprises people.

**A website trigger is a substring match on a cleaned URL.** Before comparing, Zerm
lowercases both the current URL and the one you configured, and strips `https://`,
`http://` and `www.` from each. It then checks whether the cleaned current URL
*contains* the cleaned trigger.

So a trigger of `github.com` matches all of these:

| Current URL | Matches |
| --- | --- |
| `https://github.com/arcusis/Zerm` | yes |
| `https://www.github.com` | yes |
| `https://gist.github.com/someone` | yes |
| `https://notgithub.com.example.net` | yes — the string still appears |

Two consequences worth knowing:

- A short trigger catches more than you expect. `mail` matches `gmail.com`,
  `mail.proton.me`, and any page with `mail` anywhere in its path or query string.
- Only the scheme and `www.` are stripped. Everything else — subdomain, path, query —
  is still part of the string being searched, so you can scope a mode to
  `github.com/arcusis` or `docs.google.com/spreadsheets` if you want it narrower.

Reading the active tab's URL uses AppleScript, so macOS will ask for Automation
permission for that browser the first time. Decline it and website triggers simply never
match; application triggers keep working.

Zerm waits at most half a second for the browser to answer, so recording is never held
up. A browser that answers later is treated as if no website matched.

Supported browsers: Safari, Chrome, Edge, Brave, Arc, Opera, Vivaldi, Orion, and Yandex.

## The default mode

One mode can be marked as the default. It is what applies everywhere you have not
configured something more specific. Zerm creates three modes when you have none:

- **General** — the default. No triggers.
- **Code** — Cursor, Visual Studio Code, Xcode, Terminal, iTerm, Warp, plus the website
  trigger `github.com`.
- **Writing** — Mail, Notes, Chrome, Safari.

All three use your global settings until you change them. Rename them, retrigger them,
or delete them.

## What a mode can change

Each of these can stay on **Use global setting** or be set for the mode.

### Transcription

**Model.** A mode used for quick replies can run a small local model while a mode used
for long-form dictation runs a large one. See [models](models.html).

**Language.** Pin the language you will actually speak in that app. Auto is for modes
where you switch. Pinning Hebrew and then speaking English produces broken Hebrew — that
is the speech model doing what it was told.

### Text

- **Text Formatting** — on or off.
- **Punctuation** — keep punctuation, remove all punctuation, or remove only the trailing
  period.
- **Lowercase** — on or off.

Lowercase plus punctuation removal is a common combination for chat and commit messages.
Punctuation and lowercase exist only here, per mode.

### AI enhancement

**Output.** Instant, Instant + Refine, or Enhanced for this mode. See
[output modes](output-modes.html).

When the output uses AI, a mode can also choose the **AI Provider**, the **AI Model**,
the **Enhancement Prompt**, and whether **Context Awareness** is on. A prompt that
formats email is wrong for a terminal, which is the most common reason to create a mode.
See [AI enhancement](enhancement.html) and
[contextual awareness](contextual-awareness.html).

### Advanced

**Auto Send.** A mode can press a key for you once the text is inserted: Return,
Shift + Return, or Command + Return. Set on a mode scoped to a chat app, this turns
dictation into speak-and-send. Because the message is sent straight away, a mode with
Auto Send uses Enhanced instead of Instant + Refine, so what is sent is already final.
Leave it as None everywhere you might still want to edit before sending.

**Keyboard Shortcut.** Activates the mode and starts recording in one press — useful
when you want a specific mode regardless of where you are.

While the recorder is on screen, ⌥1 through ⌥0 select the first ten enabled modes
directly. ⌘1 through ⌘0 select enhancement prompts.

## Turning Power Mode off

The master toggle in Settings will not switch off while any mode is still enabled — Zerm
tells you to disable or remove the modes first, rather than silently keeping matching
logic running behind a switch that reads off.
