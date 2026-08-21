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

Enhancement and Read Aloud both default to **Gemma 4 E2B**. The 2.8.3 move to Qwen3 was reversed on measurement: Gemma 4 E2B is the only catalogue model that keeps mixed Hebrew/English/Russian in its original script (22/22 across three runs), while every smaller candidate translated it. See [[Zerm On-Device LLM]] and GitHub #302, #307.

## The prompt earns its shape from measurement

Against Gemma 4 E2B over a 20-case dictation set, three runs each:

| wording | score | never-answers | already-clean preserved |
|---|---|---|---|
| numbered rules (2.8.3) | 9/20 | 1/3 | 1/2 |
| two absolute rules first | **13/20** | **3/3** | **2/2** |

Burying "never answer" as item 4 in a list let the model reply *"the capital of France is Paris."* to a dictated question. Leading with the rule and showing a worked failure fixed it on every model tested; Qwen2.5 1.5B went 1/3 to 3/3.

Three findings worth keeping:

- **A fully abstract example is worse.** Replacing the worked failure with placeholders dropped the score and the model started answering questions again in 1 of 3 runs. The contrast is what small instruct models follow, not the prohibition.
- **The never-translate example must carry no language and no foreign script.** 2.8.2 named Hebrew and small models translated *into* it. A variant using a real Hebrew example measured identical to the neutral one, so neutrality is free — take it.
- **The never-answer example must not carry a fact.** "what is the capital of france" → "What is the capital of France?" caused a semantically identical *Russian* question to come back as that exact English sentence. The example is now one whose echo teaches nothing.

The prompt also tells the model not to echo the prompt's own tags: Qwen3 wrapped its answer in `<TRANSCRIPT>` markup, which pasted literal scaffolding into the user's document. `AIEnhancementOutputFilter` strips those section tags as a backstop.

Related: [[Zerm Refine In Place]], [[Zerm Read Aloud]], GitHub #300.
