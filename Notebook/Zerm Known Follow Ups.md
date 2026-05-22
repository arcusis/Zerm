# Zerm Known Follow Ups

Open work tracked in `arcusis/Zerm` GitHub Issues. ~168 open as of 2026-05-22.

## Active P1 Bugs (open in GitHub)

| Issue | Title | Notes |
|-------|-------|-------|
| Z#2 / VI#672 | High CPU / battery drain in background | Root cause unknown; likely polling. Needs profiling. |
| Z#166 / VI#381 | API keys stored in UserDefaults plaintext | Should migrate to Keychain via `APIKeyManager` |
| Z#173 / VI#632 | Parakeet V3 hangs after partial FluidAudio migration | 120 s timeout now prevents infinite hang; root cause needs `FluidAudioTranscriptionService` error surfacing |
| Z#199 / VI#687 | Intermittent empty transcription | Partially fixed by model-load wait; may still occur if model context goes nil mid-session |

## Active P2 Bugs (open in GitHub)

| Issue | Title |
|-------|-------|
| Z#177 / VI#537 | Privacy disclosure — screen/clipboard data not documented |
| Z#175 / VI#702 | Numeric words → digits (Whisper prompt updated, monitor) |

## Licensing System Dead Code

`PolarService.swift`, `LicenseManager.swift`, `LicenseViewModel.swift`, `LicenseView.swift`, `LicenseManagementView.swift` — VoiceInk's paid licensing system. Zerm is GPLv3 and hardcodes `.licensed` everywhere. This is safe-but-dead code; remove in a future cleanup pass once the cost/benefit is clear.

## Known Constraints

- **Intel (x86_64) DMG** — not yet available. Only Apple Silicon build is published. Would need a CI self-hosted runner or Intel Mac.
- **Developer ID signing** — Z#1 is open. All current releases are ad-hoc signed and require "allow anyway" in Gatekeeper.
- **macOS 26 compatibility** — `KeyboardShortcuts` package (2.4.0) uses Carbon `RegisterEventHotKey` which may have issues on macOS 26 with the "custom" hotkey option. The modifier-key path (NSEvent flagsChanged) is confirmed working.
- **Ollama persistence** — Ollama must be manually started with `ollama serve` after reboot; not persisted as a login item.

## Code Quality Backlog

- Add `@MainActor` to `SystemInfoService` callers in `LogExporter.swift` if needed
- Remove `ProBadge`, `LicenseView`, `LicenseManagementView`, `LicenseViewModel`, `PolarService`, `LicenseManager` once `.licensed` hardcode is confirmed safe to leave permanent
- `ZermTests/` and `ZermUITests/` are boilerplate only — no actual test coverage

Related: [[Zerm Overview]], [[Zerm Architecture]], [[Zerm Production History]]
