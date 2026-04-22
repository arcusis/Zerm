# Zerm Known Follow Ups

## Auto-Paste

- Validate direct Accessibility insertion across real target apps: Arc/Chrome text fields, Slack, native TextEdit, terminal prompts, and coding agent input fields.
- Keep failures explicit. The HUD/dashboard should distinguish copied, pasted, no-target, permission-needed, and failed states.
- Keep clipboard success as a prerequisite for paste.
- Implement Windows SendInput and Linux X11 paste behind platform services. Keep Linux Wayland copy-only or explicitly unsupported until compositor-specific support is proven.

## macOS Permissions

- Continue treating rebuilt local apps as potentially needing fresh Accessibility approval.
- Keep the interactive auto-paste self-test explicitly gated so it never inserts into a focused app by accident.

## Docs

- Keep README, website, and `docs/native-writing-layer-verification.md` aligned with the actual production support matrix.
- Do not claim Windows/Linux auto-paste as production-ready until the native helpers and diagnostics exist.

## Security And Reliability

- Review Dependabot/RustSec alerts separately; recent pushes reported existing GitHub dependency alerts.
- Keep Linux Ollama explicitly unverified unless there is a stronger trusted package/runtime verification path.
- Preserve bounded downloads and memory caps.

Related: [[Zerm Auto Paste]], [[Zerm Setup And Permissions]]
