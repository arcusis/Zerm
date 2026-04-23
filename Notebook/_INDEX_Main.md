# Zerm Notebook

Last updated: 2026-04-23

This notebook captures durable project context for Zerm. Start here, then follow the linked notes relevant to the task.

## Core Notes

- [[Zerm Overview]]
- [[Zerm Runtime Privacy Model]]
- [[Zerm Auto Paste]]
- [[Zerm Setup And Permissions]]
- [[Zerm Production History]]
- [[Zerm Verification Workflow]]
- [[Zerm Known Follow Ups]]

## Current Local State

- Branch: `Production`
- Tracking: `origin/Production`
- Latest production recovery fixed macOS Right Option capture, pill visibility, microphone capture, and Notes insertion.
- Developer ID signed macOS builds must include `com.apple.security.device.audio-input`; without it, System Settings can show Microphone enabled while AVFoundation/CPAL still produce denied or silent capture.
- The current app records microphone device name, sample format, raw sample count, and peak RMS so silent input, wrong device selection, and STT failures can be separated.
