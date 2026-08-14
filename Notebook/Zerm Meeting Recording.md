# Zerm Meeting Recording

Meeting recording is an application-scoped workflow, separate from short-form Dictation. `MeetingRecordingController` owns the capture lifecycle for the life of the app, so navigating away from Meetings cannot orphan an active session or its Stop control.

## Capture contract

- The user explicitly selects microphone, a running call application, or the warned all-system-audio fallback. Process capture can include audio from other tabs/helpers belonging to the selected browser.
- Room and Call audio remain separate PCM tracks. Core Audio host/sample timestamps and persisted clock anchors map both tracks onto one monotonic meeting timeline; discontinuities remain gaps rather than compressed time.
- Capture callbacks cross preallocated bounded handoffs before file I/O or model work. Source health, dropped frames, silence, app/helper churn and persistence failures are durable issues.
- Each meeting folder under `~/Library/Application Support/Zerm/Recordings/` is the recovery unit: audio tracks, atomic manifest, transcript journal and sidecar stay together.

## Model and privacy contract

The selected Dictation model and language are snapshotted before Start. Local models stay local; selecting a cloud Dictation model authorizes meeting audio transcription by that provider and the UI must disclose this before capture. A new session cannot silently switch providers after Start.

Speaker attribution is source-aware. When a provider lacks word timestamps, attribution split from a coarse transcription window is persisted and displayed as estimated rather than exact. Meeting summaries are a separate, snapshotted local-only Ollama job; they never inherit the mutable cloud Enhancement provider.

## Lifecycle and recovery

`idle → preflighting → capturing → stopping → processing → ready | partial | failed`

Stop is idempotent: all entry points await the same save/transcribe/diarize operation. Summary and retry work are bound to an immutable meeting ID, and late callbacks cannot mutate a newer session. Initial and periodic atomic manifests, plus the transcript journal, allow interrupted sessions to appear in Library with Process/Retry/Re-transcribe actions.

Playback aligns Room and Call against their persisted clocks, supports a synchronized mix plus mute/solo, and seeks transcript lines on meeting time.

Related: [[Zerm Architecture]], [[Zerm Runtime Privacy Model]], [[Zerm Setup And Permissions]], [[Zerm Verification Workflow]]
