# Lost Recording 2026-08-17

Two takes, same signature, both unrecoverable on the installed 2.8.2 build:

| Row | Time | WAV | Status |
|---|---|---|---|
| 14155 | 09:59:09 | `E87AB507-…` | gone |
| 14161 | 10:23:26 | `0F7CF451-…` | gone |

History text: `Transcription Failed: The operation could not be completed`. Duration 0, no model name. Neighbor takes (09:49, 10:21, 10:24) completed and their files remain. Production app is still 2.8.2.

## What actually failed

`Recorder.stopRecording()` closed `ExtAudioFile` on a background queue and returned immediately. Whisper then opened the same path while the long take was still flushing. `AVAudioFile` / `AVAssetReader` throw a generic Cocoa error. The 120s timeout cancel can produce the same string.

The file was never durable at the moment History was written. Recovery of 14155 and 14161 is impossible. GitHub #303.

Cancel / supersede used to delete the History row; orphan cleanup could then delete the unreferenced WAV. User cancel (`removeItem` on `recordedFile`) and dismiss-while-recording also dropped the file.

## Guardrails now

- Stop waits until ExtAudioFile is disposed and the WAV is fsynced before transcribe.
- Duration is taken from the WAV bytes and written to History before any AI work.
- Header-only / missing files never enter the pipeline.
- Cancel, timeout, and supersede keep the WAV and the History row. Retry from History.
- Failed and pending rows are excluded from audio/transcript sweeps. Orphan sweep ignores files younger than 24 hours.
- A missing `AudioRetentionPeriod` key is written as 14 days, not 0.

Related: [[Zerm Auto Stop Dictation]], [[Zerm Refine In Place]]
