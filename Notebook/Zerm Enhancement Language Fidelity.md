# Enhancement Language Fidelity

2.8.2 made Hebrew a privileged language in two places, which is why mixed dictation collapsed to Hebrew and why Russian+English could emit Hebrew that was never spoken.

1. **Whisper second pass.** `prefersHebrewForAutomaticDetection()` treated *any* Hebrew entry in `Locale.preferredLanguages` as a dictation prior. Every Auto utterance ≤20s then ran forced-`he`. The selector kept that fallback within 0.04 probability of the primary.

2. **Enhancement prompt.** Rules 5–6 named Hebrew and asked the model to pick a "predominant" language. Small instruct models translated leftover English/Russian.

2.8.3 contract:

- Keyboard layout is the only Hebrew prior. Preferred languages and the Hebrew UI are not.
- Forced-`he` runs only on Auto, Hebrew keyboard, ≤6s, and not on a confident non-English detection.
- The system prompt is language-neutral and does not name Hebrew.
- `EnhancementLanguageGuard` discards any enhancement that grows a script the input barely had, or that drops a script the input actually used. English-only → any real Hebrew share is rejected. Mixed HE+EN cannot collapse to one script.

The same contract applies outside dictation enhancement:

- Read Aloud only takes the Hebrew-only instruction path when the source is ≥65% Hebrew letters. Mixed HE+EN does not.
- A script-flipped Read Aloud rewrite is rejected the same way as a flipped enhancement.
- Meeting summaries are told to keep the original script, not to pick a "predominant" language.

Enhancement default is now Qwen3 0.6B, not Gemma. Gemma stays on Read Aloud. See [[Zerm On-Device LLM]] and GitHub #302.

Related: [[Zerm Refine In Place]], [[Zerm Read Aloud]], GitHub #300.
