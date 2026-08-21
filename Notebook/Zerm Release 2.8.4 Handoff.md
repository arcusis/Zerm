# Zerm 2.8.4 Release Handoff

Everything that could be done without hardware is done. This note is the remaining sequence, in order, with the one gate that must not be skipped.

Branch: `fix/local-llm-thinking-empty-enhancement` — PR #308, deliberately still a draft.
Tree is stamped **2.8.4 / 284**. Release notes for the Sparkle dialog: `release-notes/2.8.4.html`.

## 1. The gate — verify meeting capture on real hardware

**This is the only unverified fix in the release, and it is the one that prompted the work.**

Record a short Google Meet call in a browser. Stop it. Then read the accounting line the writer prints on close:

    log stream --predicate 'subsystem == "com.arcusis.zerm"' --style compact | grep "system-audio capture"

or from the debug log at `~/Library/Application Support/com.arcusis.zerm/Logs/zerm-debug.log`:

    system-audio capture: wall=… written=… padded=… ratio=… deliveries=… deliveriesPerSecond=…

- `ratio` near **1.0** → fixed, proceed.
- `ratio` near **0.5** → not fixed. Stop. `padded` will show whether gap filling ran at all.

Also confirm the call track and the microphone track stay in sync in playback, and that the transcript covers the whole meeting rather than the first half.

Why this matters: browser capture uses the same `.application` tap scope that reproduced the defect. The fix was verified against a process that stops emitting mid-capture, but never against Chrome's helper processes, which is a different shape of the same path.

## 2. Verify the rest of the meeting flow

Nothing in this tree has run a real meeting end to end.

- Recording screen shows live level meters and no transcript panel — the transcript is meant to appear only after Stop.
- Stop → processing → transcript fills in → summary if enabled.
- The machine should stay usable during capture. That was the point of moving transcription after Stop.

## 3. Confirm the enhancement repair

On first launch of this build, blanked History rows are restored. At the time of writing the store had **19** rows with an empty enhancement. Check History looks right, and that the log shows:

    Restored N History row(s) blanked by an empty enhancement

The completion flag was deliberately cleared, so the repair will run. Do not run `xcodebuild test` before launching the app if you want to observe it — the test host *is* the app, so tests trigger launch migrations against the real install. That is how the retired model files were deleted during development.

## 4. Build the signed release

    RELEASE_NOTES_FILE=release-notes/2.8.4.html scripts/release.sh

`release.sh` refuses to run without release notes, by design. It generates `docs/appcast.xml` and the root copy itself, signs the update with Sparkle's `sign_update`, and fails closed rather than writing an unsigned appcast.

Two things in this release have never run through a signed build:

- The **branded DMG window**. It was verified by building unsigned DMGs and opening them, but not through `release.sh`. If Finder scripting fails the script logs a warning and ships an unstyled DMG rather than failing the release.
- The **update-from-public-build** path.

## 5. Publish

- `gh release create v2.8.4` with the DMG and the Sparkle ZIP.
- Regenerate the site: `docs/changelog.html` is built from GitHub releases by `scripts/build-site.mjs`, so it must run *after* the release exists. Do not hand-edit it.
- Undraft and merge PR #308.
- Close #307, #309, #310.

## What is measured, and what is not

Measured, with evidence in the linked notes:

- Enhancement returns real text — 0 empty of 22, three runs, against the prompt composed from source.
- Script fidelity 22/22 across English, Russian, Hebrew and both mixed directions.
- Latency p50 0.125 s, down from 0.452 s.
- Meeting gap padding — ratio 0.985 against a process that stops emitting mid-capture; 0.976 with no padding when audio is continuous.
- Both launch migrations, including that they delete only exact retired file names.

Not measured:

- Browser meeting capture.
- A real meeting end to end.
- A signed, notarized build, and the DMG window inside it.

Related: [[Zerm Measuring Model And Audio Claims]], [[Zerm Meeting Recording]], [[Zerm On-Device LLM]], [[Zerm Release Signing]], [[Zerm Verification Workflow]]
