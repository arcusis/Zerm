# Zerm Power Mode Inheritance

Why dictation "switched models" between apps, and how 2.8.6 fixed it (#315, PR #337).

## The defect

- **Frozen values:** `PowerModeConfig.init` replaced every `nil` override with the global value at creation time. The seeded General/Code/Writing configs therefore froze the model, language and prompt that happened to be selected. The default config matches any app, so effectively every dictation ran on those frozen values.
- **Leaking writes:** Power Mode applied overrides by writing global settings and restoring a snapshot on dismiss. Any settings change mid-session re-snapshotted, making the override permanent.
- **Mid-recording switches:** a late browser-URL match could switch the config mid-recording.
- **Forced formatting:** formatting, punctuation and lowercase had no UI but were forced on every session, so formatting was effectively off for everyone.

## The design now

- **Optional overrides:** every override is optional, and `nil` means "Use global setting". This covers model, language, output mode, prompt, provider, AI model, context, formatting, punctuation and lowercase.
- **Resolved once:** `DictationSessionConfiguration` is resolved once per recording, after audio capture has already started. Session, pipeline, History and enhancement read it; nothing is written globally.
- **Stale resolutions:** `DictationSessionTracker` discards a resolution whose recording stopped or was replaced during the browser URL wait (capped at 0.5 s). An early stop falls back to the app/default Power Mode.
- **Recorder controls:** ⌘E, the prompt shortcuts and the popover change only the live recording.

## Migration (`PowerModeMigration`)

- **Interrupted session:** restores an interrupted 2.8.5 session snapshot first.
- **Clears frozen copies only:**
  - values equal to the current global setting
  - the Default prompt and `en` that seeding wrote
  - model names saved with On-Device (2.8.5 saved the Read Aloud model there)
  - transcription-only providers
- **Explicit writes:** every override is written in the new format, including explicit inherit, so a leftover `isAIEnhancementEnabled` cannot flip a mode.
- **Formatting:** if an enabled 2.8.5 Power Mode forced formatting off, global `IsTextFormattingEnabled` is set to false, so output doesn't change on update.

Related: [[Zerm Enhancement Pipeline]], [[Zerm Speech Model Catalog]]
