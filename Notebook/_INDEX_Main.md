# Zerm Notebook

Last updated: 2026-05-22

This notebook captures durable project context for Zerm. Start here, then follow the linked notes relevant to the task.

## Core Notes

- [[Zerm Overview]]
- [[Zerm Architecture]]
- [[Zerm Runtime Privacy Model]]
- [[Zerm Auto Paste]]
- [[Zerm Setup And Permissions]]
- [[Zerm Production History]]
- [[Zerm Known Follow Ups]]

## Current State (2026-05-22)

- Branch: `Production`  
- Latest release: `v1.0.0` (Apple Silicon DMG only — Intel build not yet available)
- **The Tauri prototype has been fully removed.** Zerm is now a pure native macOS Swift/SwiftUI app.
- All upstream VoiceInk issues tracked in `arcusis/Zerm` GitHub Issues (~168 open).

## Quick Build Reference

```bash
make local         # build + install to ~/Applications (unsigned, local dev)
make reset-permissions  # tccutil reset Accessibility + ScreenCapture
```

Full build guide: `BUILDING.md`
