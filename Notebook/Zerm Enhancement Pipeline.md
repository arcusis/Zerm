# Zerm Enhancement Pipeline

The AI enhancement design after the 2.8.6 rebuild (#322, PR #337). It replaces the pre-2.8.6 system, where settings were read from shared mutable state at unpredictable times.

## Rules

1. **One switch.** `DictationOutputMode` (instant / instantRefine / enhanced) decides whether enhancement runs. `isEnhancementEnabled` is derived from it, and `LastEnhancingDictationOutputMode` remembers what ⌘E restores.
2. **A frozen request.** An `EnhancementRequest` is built once per dictation, before the recorder is dismissed. It fixes the prompt (trigger words resolved), provider, model, endpoint, context snapshot, timeout and language policy. Model precedence: Power Mode, then prompt override, then global.
3. **One executor.** `EnhancementExecutor` runs the request:
   - Ollama reachability check (1.5 s)
   - deadline
   - cancellation, including retry sleeps; Local CLI processes get SIGTERM then SIGKILL
   - output filter
   - empty check
   - `EnhancementLanguageGuard`
   Dictation, refine, History re-enhance and quick actions all use it.
4. **Pipeline order** (`TranscriptionPipeline`):
   1. Transcribe.
   2. Deterministic cleanup: filter/fillers, formatting, word replacement, dictation commands.
   3. User preferences applied; this is the Instant paste.
   4. LLM on the cleaned text.
   5. Preferences re-applied to the LLM output.
   Prompts must not repeat the deterministic steps.
5. **Honest outcomes.** `Transcription.enhancementOutcome` records enhanced / skipped / failed / rejected. A guard rejection never writes `enhancedText`. `EnhancementNotifier` reports "not configured" once per launch, and transient failures at most every 2 minutes.

## Timeouts and context

- **Timeouts:** Enhanced uses the Timeout setting (default 15 s). Refine has an 8 s budget under a 10 s hard deadline.
- **Screen context:** OCR only for Enhanced, with the wait capped at 1 s.
- **Clipboard:** captured at start, and only when the dictation can use AI.

## Prompts

A per-prompt "May change language or length" flag exempts translate and expand prompts from the script and 4× length guard. It is on for Assistant and Email.

## Providers

- **Excluded:** transcription-only providers never appear in enhancement pickers.
- **Ollama:** one model key, `ollamaSelectedModel`.
- **On-device:** uses the selected enhancement model, falling back to an installed model that can enhance; never a read-only model.
- **Prewarm:** only when this dictation will use the local LLM.

Related: [[Zerm Power Mode Inheritance]], [[Zerm Refine In Place]], [[Zerm Enhancement Language Fidelity]], [[Zerm On-Device LLM]]
