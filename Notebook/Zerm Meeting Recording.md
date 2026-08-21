# Zerm Meeting Recording

Meeting recording is an application-scoped workflow, separate from short-form Dictation. `MeetingRecordingController` owns the capture lifecycle for the life of the app, so navigating away from Meetings cannot orphan an active session or its Stop control.

## Capture contract

- The user explicitly selects microphone, a running call application, or the warned all-system-audio fallback. Process capture can include audio from other tabs/helpers belonging to the selected browser.
- **A process tap only fires while the captured app is emitting audio.** Measured against the shipped tap: 91.6 deliveries/second for a whole-system tap against 10.5 for an application tap, at the same 512 frames per delivery. Silence produces no callbacks at all, so gaps must be written as real silence or the track becomes time-compressed rather than gapped — see the 2.8.4 entry below.
- Room and Call audio remain separate PCM tracks. Core Audio host/sample timestamps and persisted clock anchors map both tracks onto one monotonic meeting timeline; discontinuities remain gaps rather than compressed time.
- Capture callbacks cross preallocated bounded handoffs before file I/O or model work. Source health, dropped frames, silence, app/helper churn and persistence failures are durable issues.
- Each meeting folder under `~/Library/Application Support/Zerm/Recordings/` is the recovery unit: audio tracks, atomic manifest, transcript journal and sidecar stay together.

## Transcription happens after Stop

Capture records audio only. Nothing runs a model while `capturing`, so a meeting stays light on the CPU — the previous design ran a `MeetingTranscriber` per source over 30-second windows *during* capture, competing with the audio thread, and on the local path threw that work away afterwards because the canonical pass re-ran the same audio. A 94-second meeting produced a transcript journal of two lines.

The `processing` phase does one pass per saved track, for every route. Removing the live path removed the whole coverage-reconciliation layer with it: `liveTranscribers`, `liveGaps`, `liveCoverage`, uncovered-range retry, and the live-vs-canonical strategy split. `liveCloudCoverageWithGapRetry` remains only in the persisted enum so older manifests still decode.

Starting a meeting no longer refuses without a Dictation model: a model is needed to transcribe *after* Stop, not to capture, and refusing would throw away audio that cannot be re-recorded.

## Model and privacy contract

The selected Dictation model and language are snapshotted before Start. Local models stay local; selecting a cloud Dictation model authorizes meeting audio transcription by that provider and the UI must disclose this before capture. A new session cannot silently switch providers after Start.

Speaker attribution is source-aware. When a provider lacks word timestamps, attribution split from a coarse transcription window is persisted and displayed as estimated rather than exact. Meeting summaries are a separate, snapshotted local-only Ollama job; they never inherit the mutable cloud Enhancement provider.

## Lifecycle and recovery

`idle → preflighting → capturing → stopping → processing → ready | partial | failed`

Stop is idempotent: all entry points await the same save/transcribe/diarize operation. Summary and retry work are bound to an immutable meeting ID, and late callbacks cannot mutate a newer session. Initial and periodic atomic manifests, plus the transcript journal, allow interrupted sessions to appear in Library with Process/Retry/Re-transcribe actions.

Playback aligns Room and Call against their persisted clocks, supports a synchronized mix plus mute/solo, and seeks transcript lines on meeting time.

Related: [[Zerm Architecture]], [[Zerm Runtime Privacy Model]], [[Zerm Setup And Permissions]], [[Zerm Verification Workflow]]
