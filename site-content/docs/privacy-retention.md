---
title: Privacy and retention
eyebrow: Privacy
summary: What Zerm keeps, for how long, and which of the two auto-delete settings actually deletes what.
---

Zerm stores two different things after a recording, and they are governed by two
different settings. Confusing them is the usual reason people find audio still on disk
when they expected it gone, or history emptier than they wanted.

- The **transcript** — the text, plus its timestamp, duration, model, and enhancement
  result. Stored in the app's local database.
- The **audio** — the recording itself, as a file in the app's Application Support
  folder.

Both stay on your Mac. Neither is uploaded anywhere by Zerm.

![Retention settings](img/privacy-retention.png)

## Transcript auto-delete

*Setting: "Delete transcripts automatically", off by default.*

When enabled, transcripts older than the retention period are deleted, and their audio
goes with them. The default period is 24 hours.

The sweep runs at launch and again after every completed transcription, so a long
uptime does not let old entries linger.

Set the retention period to zero and each transcript is deleted the moment it completes
— the text goes to your cursor and nothing is written to history at all. If you want a
dictation tool that keeps no record, this is the setting.

Enabling transcript auto-delete also cleans up **orphan audio files**: recordings left
on disk with no transcript pointing at them.

## Audio auto-delete

*Setting: "Delete audio files automatically", on by default, 14 days.*

This deletes the recordings and keeps the transcripts. The history entry survives with
its text intact; only the playable audio and its disk space go away.

The check runs at launch and once a day thereafter. You can also run it on demand from
Settings, which first tells you how many files it would remove and how much space that
frees.

This is the setting most people want. Audio is the bulk of the disk usage and the part
with the most sensitive content, while the transcript is the part that is actually
useful to search later.

## The two together

| | Transcript text | Audio file |
| --- | --- | --- |
| Transcript auto-delete | deleted | deleted |
| Audio auto-delete | kept | deleted |

Running both is reasonable: audio at 14 days for the disk space, transcripts at a longer
period for the searchable record.

## Usage statistics are separate

Your usage statistics — words dictated, time saved, sessions, words read aloud — live in
their own store, deliberately apart from the transcripts.

**Deleting transcripts does not affect your statistics.** That is deliberate. The
dashboard used to recompute every number by scanning surviving transcript rows, so
turning on aggressive retention meant watching your totals evaporate — the privacy
setting and the dashboard were effectively mutually exclusive. They are now independent:
totals are accumulated as work completes, never recomputed from history. You can keep no
transcripts at all and still have an accurate dashboard.

What is stored is one row per day of counts and durations. No transcript text, no audio,
nothing that could reconstruct what you said — which is why it stays safe to keep even
when you are running zero retention.

**Two caveats if you are upgrading.** Durable statistics start from this version.
Upgrading backfills what it can from the transcripts you still have, so anything an
earlier retention sweep already deleted cannot be recovered — the all-time totals for
those installs begin at the upgrade rather than at first launch. Read Aloud totals from
before this version were only ever kept as a lifetime count, so they are attributed to
the upgrade date; the all-time figure is right, the daily breakdown for that stretch is
not.

### Clearing your statistics

**Reset Statistics**, in Privacy settings, permanently clears every recorded day along
with the Read Aloud counters. Nothing survives it and it cannot be undone.

It does not touch your transcripts or your audio — those have their own controls, above.
The three are independent in both directions: deleting history leaves your statistics
alone, and resetting your statistics leaves your history alone.

Cleared statistics stay cleared. Keeping transcripts does not repopulate them later —
the one-time backfill described above does not run a second time, because rebuilding
your totals from surviving history is the opposite of what clearing them means.

## Deleting things yourself

Nothing here replaces doing it by hand. From History you can delete individual
transcripts or clear the lot, and each deletion takes its audio file with it.

## What leaves your Mac

Only what you configure:

- **Local transcription** — Whisper, Parakeet, Apple Speech — never sends audio
  anywhere.
- **Cloud transcription** sends the audio to the provider you selected, and only once
  you have added a key and chosen that model.
- **Enhancement** sends the transcript, the active prompt, and whichever context sources
  you switched on. The on-device provider sends nothing at all.
- **Read Aloud** sends the text to a cloud voice provider if you selected one; the
  bundled local voice does not.
- **Announcements and update checks** fetch from this site and from GitHub Releases.
  They send no content and can be switched off in Settings.

More detail on the context sources is on the
[contextual awareness](contextual-awareness.html) page.
