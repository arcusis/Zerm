# Zerm Notebook

Last updated: 2026-04-22

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
- Latest shipped production fixes include `d8894ad Fix macOS overlay and signed prerelease trust` and `f6f4b21 Repair local macOS accessibility and pill presentation`.
- The local `/Applications/Zerm.app` rebuilt during development is ad-hoc signed. That can make System Settings show an enabled Accessibility row while `AXIsProcessTrusted()` still reports the current binary as untrusted.
- The current native-writing-layer update adds platform abstraction scaffolding, insertion strategy planning, dashboard diagnostics, VAD diagnostics, profile/model/vocabulary scaffolding, and verification docs/scripts.
