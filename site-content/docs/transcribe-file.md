---
title: Transcribe File
eyebrow: Speech
summary: Drop in an audio or video file and get a full transcript, with each speaker identified, renameable, and ready to export.
---

Transcribe File turns an existing recording into text: an interview, a lecture, a voice
memo, a video call you recorded elsewhere. It uses the same models as dictation and,
when you want it, works out who said what.

## Adding files

Open **Transcribe File** in the sidebar, then either:

- **Drop files** anywhere on the page, or
- **Choose Files…** to pick one or more.

You can also start from Finder: **Open With → Zerm** on any audio or video file, or drop
it on Zerm's Dock icon. The file joins the queue and Zerm opens Transcribe File.

MP3, M4A, WAV, FLAC, MP4, MOV, and most other audio and video formats work. For a video,
only its first audio track is transcribed. There is no length limit; hour-long files are
fine.

## Options

The **Options** box applies to the files you add next. Each file keeps the options it
was added with.

- **Model** — any downloaded local model, or any cloud model you have added a key for.
  It starts as your dictation model. See [models](models.html).
- **Language** — the language to transcribe. Models that detect the language themselves
  show that instead.
- **Identify speakers** — on by default. Labels each part of the transcript with the
  voice that spoke it.
- **Speakers** — **Detect automatically**, or tell Zerm how many people are in the
  recording, from 2 to 10. A known count helps when voices sound alike.

Speaker identification runs on your Mac. Its model downloads the first time you use it.

## The queue

Files are transcribed one at a time, in the order you added them. Each row shows its
progress — preparing audio, identifying speakers, transcribing — and a **Cancel**
button.

A failed or cancelled file offers **Retry**. **Clear Finished** tidies the list. The
queue is not kept when you quit Zerm, but finished transcripts are, in History.

## The transcript

Click a finished file, or **View Transcript**, to open it.

- **Speakers.** Each voice gets a colour and a name field. Type a real name and press
  Return; every line and export uses it. Clear the field to go back to "Speaker 1".
  Speaker 1 is always the first voice heard.
- **Timestamps.** Each paragraph starts with the speaker and the time. Click the time to
  play the audio from there.
- **Copy** puts the whole transcript, with speaker names, on the clipboard.

## Exporting

The **Export** menu saves the transcript in five formats:

| Format | Use it for |
| --- | --- |
| Plain Text (.txt) | reading, with a timestamp and speaker on every line |
| Markdown (.md) | notes and documents |
| SubRip Subtitles (.srt) | subtitles for most video players and editors |
| WebVTT Subtitles (.vtt) | subtitles for the web |
| JSON (.json) | scripts and other tools: segments, timings, and speakers |

Subtitle cues are kept short: at most seven seconds and two lines each. Hebrew and
English mixed in one line keep their correct direction.

## History

Every finished file is saved to History like a dictation, with its audio. Right-click the
entry, or expand it, and choose **Open Transcript** to get the full speaker view back,
including renaming and export.

[Retention settings](privacy-retention.html) apply to file transcripts too. When the
audio is deleted, the transcript still opens, without playback.

## What gets applied

Your [dictionary](dictionary.html) helps here as it does in dictation: word replacements
are applied, and vocabulary is passed to models that use it. AI enhancement and prompts
are not applied to file transcripts.

## When speakers are not identified

- **Identify speakers is off.** You get a plain transcript with timestamps.
- **Speaker identification failed**, usually because its model could not download. The
  file still completes, marked **Completed without speakers**. Check your connection and
  retry the file.
- **Part of the file could not be transcribed.** The transcript says which time ranges
  are missing.

A file with no recognisable speech fails with "No speech was recognized in this file."
