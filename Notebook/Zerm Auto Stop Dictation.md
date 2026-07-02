# Zerm Auto Stop Dictation

Hands-free ("automatic") dictation: `ZermEngine.startAutoStopMonitor()` runs a 200 ms loop while recording — silence auto-stop (default 2.5 s, opt-out) plus a dropped-capture watchdog (3 s without audio input → recover).

## Gotcha (fixed 2026-07-02): monitor must NOT await toggleRecord

The monitor lives in `autoStopTask`. `toggleRecord()`'s first step on stop is `cancelAutoStopMonitor()` — so `await self.toggleRecord()` from inside the monitor **cancelled its own task**, and the whole stop → transcribe → paste pipeline ran in an already-cancelled task:

- `Task.sleep` inside `withTranscriptionTimeout` throws `CancellationError` immediately → pipeline's cancellation handler fired.
- Before PR #242 this surfaced as 50+/day "Transcription Failed: (Swift.CancellationError error 1.)" history entries; after #242 the pending record was **silently deleted** — capture lost, no paste, no history, no notification. PR #242 masked the symptom, not the cause.

Fix: `ZermEngine.stopFromMonitor()` — all monitor trigger points spawn an **unstructured** `Task { await toggleRecord() }`, which does not inherit the monitor's cancellation. Manual hotkey stop was never affected (different task).

Racing note: if the user hotkey-stops while the spawned stop task is queued, the second `toggleRecord` sees `.transcribing` and is ignored (`canProcessHotkeyAction` / busy branch) — no double stop.

Related: [[Zerm Architecture]], [[Zerm Overview]]
