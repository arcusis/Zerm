# Zerm File Transcription

"Transcribe File" replaced Meetings in 2.8.6 (#324 removal, #325 feature, PRs #329, #335, #336). Meetings (live dual-track capture) never worked reliably. On first launch of 2.8.6, `MeetingDataRemovalMigration` permanently deletes `Application Support/Zerm/Recordings` and the meeting defaults.

## Flow

`FileTranscriptionQueue` runs one job at a time:
1. **Convert.** `AudioFileConverter` streams to 16 kHz mono WAV, with an AVAssetReader fallback for video, m4a and mp4.
2. **Diarize,** if Identify speakers is on. FluidAudio `OfflineDiarizerManager` (pyannote Community-1 parity) runs through `FileDiarizer`.
3. **Plan spans.** `SpeakerTurnPlanner` is a pure function:
   - turns under 1 s are absorbed into neighbours
   - same-speaker turns join into spans of up to 30 s, split at pauses
   - runs of short turns from different speakers share one request of up to 15 s; only those spans estimate speakers by time share
   - each span gets padding of up to 0.2 s that never overlaps a neighbour
4. **Transcribe** each span through the engine's shared `serviceRegistry` at `.background` priority. Long single turns go through `WindowedFileTranscriber` (30 s windows, seam reconciliation). Five consecutive span failures fail the job.
5. **Fallback.** With speakers off, when diarization fails, or when no speech is found, the job takes the plain windowed path and delivers the transcript without speakers.

## Storage

- **History row:** a completed `Transcription` holds the speaker-labelled text, with audio in `root/Recordings/<id>.wav`.
- **Sidecar:** `<id>.segments.json` holds the segments and speaker names. It was chosen over SwiftData fields. History delete and auto-cleanup remove it.
- **Reopening:** History rows that have a sidecar get "Open Transcript".

## Exports

- TXT, Markdown, SRT (`00:00:01,000`), WebVTT (`00:00:01.000`) and JSON.
- Subtitle cues are at most 7 s and two lines of 42 characters.
- Unicode isolates wrap a speaker label and text of opposite direction (Hebrew/English).

## Known limits

- The queue is in memory only.
- Diarization is not scheduled against dictation, so both compete for the Neural Engine.
- A job using a different Whisper/Parakeet model swaps the loaded model.

Related: [[Zerm Speech Model Catalog]]
