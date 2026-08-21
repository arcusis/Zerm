# Measuring Model And Audio Claims

Two claims in this project cannot be settled by reading code: *which on-device model is better* and *why audio came out wrong*. Both were got wrong at least once by reasoning from artifacts. This note records how they get proved instead, and the harnesses that do it.

## Why this exists

**#309 was diagnosed wrong twice before it was diagnosed right.** The call track was half length. The first explanation — frame counting against a deinterleaved tap — was plausible, internally consistent, and shipped as a fix. It was a no-op. The second — the sample-rate converter — was also plausible and also wrong. Both died in about ten minutes once they were *measured* rather than argued.

The rule that came out of it: **a fix is not a fix until the defect has been reproduced and the fix has been observed to remove it.** A build that compiles and a test that passes prove neither.

## Proving a model claim

Never compare models by impression. Drive the real `llama.cpp` bridge with the real shipped prompt over a fixed corpus, three runs each, and score mechanically.

What made the difference in practice:

- **Use real dictation, not invented sentences.** History text is already post-formatted, so only 8 of 29 samples contained a filler word — a corpus of those cannot discriminate between models at all. Build a corpus that exercises the documented rules: fillers, stutters, self-corrections, numerals, lists, commands-that-must-not-be-answered, mixed script, and already-clean text that must survive untouched.
- **Watch for corpus contamination.** One question case was, verbatim, the prompt's own worked example. It inflated the score of every prompt variant that contained it.
- **Three runs minimum.** Single runs looked decisive and were not; Gemma 4 E2B ranges 12–14/20 across identical runs.
- **Compose the prompt from the source files**, not by hand. Testing a prompt that differs from the shipped one wastes the whole exercise.
- **Score the mixed-script cases separately.** They are the dimension that eliminated every small model, and they are invisible in an aggregate score.

## Proving an audio claim

The decisive move is to **drive the shipped classes outside the app**. `SystemAudioTap` and `SystemAudioTrackWriter` compile standalone against `Atomics` from the Xcode build products with a `DebugLogger` stub, which turns a 90-second meeting into an 8-second experiment.

    swiftc -O -profile-generate -o repro \
      SystemAudioTrackWriter.swift SystemAudioTap.swift stubs.swift main.swift \
      -I "$DERIVED/Build/Products/Debug" -I "$CHECKOUTS/swift-atomics/Sources/_AtomicsShims/include" \
      "$DERIVED/Build/Products/Debug/Atomics.o" "$DERIVED/Build/Products/Debug/_AtomicsShims.o"

`-profile-generate` is needed because the Debug `Atomics.o` carries profiling instrumentation and will not otherwise link.

The single number worth printing is **audio written per second of wall clock**. Healthy is ~1.0. The bug was 0.5, and it only appeared under `.application` scope — the variable that had never been varied.

Ground truth beats declared values. The tap's ASBD says one thing; what the IOProc actually hands over is another, and only the second matters. Probe it:

    delivery 0: mNumberBuffers=1 [ch=2 bytes=4096]

Two traps found this way:

- **The declared format is not the delivered layout.** Verify by observing an IOProc, not by reading `kAudioTapPropertyFormat`.
- **The delivery timestamp is not a wall clock.** `AudioTimeStamp.mHostTime` is derived from the device sample clock: it stops while the tap is idle and resumes where it left off, so elapsed time measured from it tracks *audio* time and a gap is invisible. Gap detection must use `DispatchTime.now()`. The first version of the #309 fix used the delivery timestamp and padded nothing.

## Reproduce before fixing

A defect that has not reproduced is a defect that has not been understood. For #309 the reproduction was: tap a process, have it stop emitting partway through, measure the ratio. That took one afternoon and would have prevented two wrong fixes.

Watch for reproductions that quietly do not reproduce anything. An early attempt tapped `afplay` in a loop — but each invocation is a new PID, so the tap died with the first one and the run proved nothing. Another played a file with embedded silence, which does not stop the audio stream and so produces no gap at all. The reproduction has to break the thing you claim is breaking.

Related: [[Zerm Meeting Recording]], [[Zerm On-Device LLM]], [[Zerm Enhancement Language Fidelity]], [[Zerm Verification Workflow]]
