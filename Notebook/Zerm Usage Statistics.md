# Zerm Usage Statistics

The durable metrics store behind the Dashboard, added 2026-07-29.

## Why it exists

The Dashboard appeared to reset itself every day. It was not a display bug.

Every number was recomputed on the fly by scanning surviving `Transcription` rows (`MetricsContent.loadMetricsEfficiently`). Nothing was ever stored. `TranscriptionAutoCleanupService` hard-deletes those rows at launch and on **every** `.transcriptionCompleted`, with a default retention of 1440 minutes — exactly one day. Lifetime totals were therefore only ever a view of whatever history had not been swept yet.

Two further defects in the same area:

- `sweepOldTranscriptions` used `max(retentionMinutes, 0)` and never read the declared `defaultRetentionMinutes`. A retention of `0` set the cutoff to `now`, deleting the **entire** history at launch.
- `AudioFileTranscriptionService` created `Transcription` records without a `transcriptionStatus`, leaving them `.pending` forever. Dropped-audio transcriptions were invisible to the dashboard predicate while still appearing in History. Legacy rows with a `nil` status were excluded the same way.

## The store

`UsageDay` in its own **`usage.store`**, a third `ModelConfiguration` alongside `default.store` (transcripts) and `dictionary.store` (CloudKit).

The separation is the whole design:

- Transcript retention cannot reach it, so clearing history no longer erases the record of use.
- It holds counts and durations only — **no transcript text** — so retaining it is safe even under zero-retention.

One row per day: sessions, words, enhanced sessions, recorded/transcribe/enhance seconds, and the Read Aloud counters.

## Things to know

- **Backfill runs once** on first launch after upgrade, bucketing existing `Transcription` rows by `startOfDay`. Anything an earlier retention sweep already deleted is **unrecoverable** — the docs say so rather than implying the history is complete.
- Pre-upgrade Read Aloud totals land on the upgrade date. The all-time figure is right; that day's breakdown is not real.
- **Refine-in-place records in two parts.** In `instantRefine` the session is counted at paste time, before the enhancement exists, so `recordDeferredEnhancement(seconds:)` adds the enhancement to that day separately rather than as a second session.
- **`resetAll()` had to be added deliberately.** While metrics were derived from transcripts, clearing history cleared them as a side effect; making them durable silently removed the only way to erase them. It also clears the two legacy `TTSSettings` Read Aloud counters. The backfill marker is left set on purpose — re-backfilling would repopulate from surviving transcripts, the opposite of what "clear" means.

## Dead weight removed with it

- `DashboardPromotionsSection.swift` — both `shouldShow*` hardcoded `false`; 160 lines of unreachable "Zerm Pro" and affiliate upsell inherited from VoiceInk.
- `MetricsSetupView.swift` — no references anywhere.

Related: [[Zerm Runtime Privacy Model]], [[Zerm Refine In Place]], [[Zerm Architecture]]
