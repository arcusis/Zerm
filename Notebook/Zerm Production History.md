# Zerm Production History

Recent production work centered on privacy hardening, setup UX, local app rebuilds, and auto-paste reliability.

## Recent Commits

- `ebcbbc8 Add verified macOS auto-paste insertion path`
- `b8ef4c0 Fix macOS auto-paste execution`
- `10afb52 Keep auto-paste gated on Accessibility trust`
- `1429e59 Request Accessibility before enabling auto-paste`
- `ce0d3d6 Make auto-paste permission failures visible`
- `f200f51 Address privacy and reliability review findings`
- `ab3839b Harden auto-paste and improve about page`
- `b33643e Fix macOS auto-paste focus restore`

## Notable Shipped Changes

- Release pipeline now treats prerelease CI differently from stable releases: macOS prereleases use Tauri `--skip-stapling` after signing so Apple notarization polling outages do not fail the build, and Windows prereleases can publish unsigned installers when signing secrets are absent.
- macOS signed builds now carry the audio-input entitlement required for microphone capture under hardened runtime.
- The app now separates Accessibility permission, Microphone permission, selected input device, capture level, STT, and insertion diagnostics.
- Right Option capture has a CoreGraphics event-tap fallback for side-specific modifier keys.
- The pill is forced onto the primary monitor and configured as a high-level visible overlay to avoid off-screen/stale monitor placement.
- Recording uses tap-to-toggle semantics: tap Right Option to start, tap again to stop; quick release no longer immediately stops capture.
- Dashboard has a Start/Stop fallback and microphone picker.
- Auto-paste failures are no longer silent.
- Auto-paste enabling requests/checks Accessibility permission.
- Auto-paste and hotkey readiness are separate concepts.
- Clipboard failure skips auto-paste, history save, dashboard done state, and normal done event.
- Linux Ollama trust wording and behavior were downgraded to explicit unverified opt-in.
- Recording memory cap was lowered to reduce peak memory risk.
- macOS Ollama install now backs up and rolls back instead of removing the old app before replacement is verified.
- README, website, and About page were updated with repository links, privacy model, release links, and platform caveats.

## Local Install Notes

Local macOS builds have been installed by:

- building with `pnpm tauri build --bundles app`,
- Developer ID signing with `src-tauri/Entitlements.plist`,
- replacing `/Applications/Zerm.app`,
- launching `/Applications/Zerm.app`.

Because these are rebuilt local app bundles, macOS may require Accessibility or Microphone permission to be reset and re-granted after entitlement/signing changes.

Related: [[Zerm Verification Workflow]], [[Zerm Auto Paste]]
