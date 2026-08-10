# Zerm Known Follow Ups

Open work is tracked in `arcusis/Zerm` GitHub Issues. Issue counts and tracker status change independently of this notebook; verify GitHub before using them as a current release gate.

## Active P1 Bugs (open in GitHub)

| Issue | Title | Notes |
|-------|-------|-------|
| Z#2 / VI#672 | High CPU / battery drain in background | Root cause unknown; likely polling. Needs profiling. |
| Z#173 / VI#632 | Parakeet V3 hangs after partial FluidAudio migration | 120 s timeout now prevents infinite hang; root cause needs `FluidAudioTranscriptionService` error surfacing |

## Recently Closed Tracker Items

- **Z#199 / VI#687 — intermittent empty or truncated transcription:** closed in GitHub on 2026-06-14. Reopen with fresh runtime evidence if the symptom returns.
- **Z#175 / VI#702 — numeric words converted to digits:** closed in GitHub on 2026-05-22 after the Whisper prompt correction and monitoring period.

## Resolved in the Current Branch

- **Z#166 / VI#381 — Release credential storage:** shipped Release builds now store API keys in the macOS Keychain and migrate verified legacy `LocalKeychain_*` values before removing their plaintext copies. The `DEBUG`-only `UserDefaults` fallback remains intentional for unsigned/ad-hoc developer builds and is not the shipped behavior.
- **Z#177 / VI#537 — context privacy disclosure:** permission/onboarding and context-toggle copy now discloses in English and Hebrew that screen/clipboard text can be sent to the configured enhancement provider. The website contextual-awareness documentation also describes this boundary.

## Licensing System Dead Code

`PolarService.swift`, `LicenseManager.swift`, `LicenseViewModel.swift`, `LicenseView.swift`, `LicenseManagementView.swift` — VoiceInk's paid licensing system. Zerm is GPLv3 and hardcodes `.licensed` everywhere. This is safe-but-dead code; remove in a future cleanup pass once the cost/benefit is clear.

## Known Constraints

- **Intel (x86_64) DMG** — not yet available. Only Apple Silicon build is published. Would need a CI self-hosted runner or Intel Mac.
- **Release identity and notarization** — Z#1. The Developer ID/notary/Sparkle pipeline and a no-local-rebuild `PREBUILT_APP` path now exist (see [[Zerm Release Signing]]), but unsigned Office builds do not prove release readiness. Each release still requires verified signing and notary credentials on the signing Mac, a successful fail-closed packaging run, both exact GitHub assets, and Gatekeeper plus installed-runtime verification.
- **macOS 26 compatibility** — `KeyboardShortcuts` package (2.4.0) uses Carbon `RegisterEventHotKey` which may have issues on macOS 26 with the "custom" hotkey option. The modifier-key path (NSEvent flagsChanged) is confirmed working.
- **Ollama persistence** — Ollama must be manually started with `ollama serve` after reboot; not persisted as a login item.

## Code Quality Backlog

- Add `@MainActor` to `SystemInfoService` callers in `LogExporter.swift` if needed
- Remove `ProBadge`, `LicenseView`, `LicenseManagementView`, `LicenseViewModel`, `PolarService`, `LicenseManager` once `.licensed` hardcode is confirmed safe to leave permanent
- Meeting recording now has deterministic architecture/contract tests, but UI-test execution requires an unlocked, user-authorized Aqua session. The no-microphone Office Mac cannot replace final microphone, wired/AirPods/Bluetooth/USB route-disconnect, VoiceOver, localization/RTL, installed-quarantine, or previous-version Sparkle-update runtime gates described in [[Zerm Verification Workflow]].

Related: [[Zerm Overview]], [[Zerm Architecture]], [[Zerm Production History]]
