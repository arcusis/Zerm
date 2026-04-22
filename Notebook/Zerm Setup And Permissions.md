# Zerm Setup And Permissions

Zerm setup covers model availability, local Ollama availability/trust, and platform input permissions.

## Setup Sequence

1. Whisper model: download `ggml-small.bin` into app data and load it.
2. macOS Accessibility permission: required for modifier-key recording and auto-paste.
3. Ollama: install official local app when missing, or allow user opt-in to an existing local service.
4. Gemma model: pull the configured local model through Ollama.

## macOS Accessibility

macOS can show an existing `/Applications/Zerm.app` entry in Accessibility while a rebuilt local bundle still does not have effective trust. The app should:

- check Accessibility whenever enabling auto-paste,
- use `AXIsProcessTrusted()` as the authoritative runtime check for the current process,
- open System Settings to Privacy and Security -> Accessibility when blocked,
- reset stale local TCC entries for ad-hoc/rebuilt development bundles when appropriate,
- make failures visible in the dashboard/pill rather than silently copying only.

Public alpha/production builds should be Developer ID signed and notarized. Local ad-hoc builds are useful for development, but they are not stable TCC identities and should not be used to judge production Accessibility behavior.

Manual recovery when trust is stale:

1. Quit Zerm.
2. Open System Settings -> Privacy and Security -> Accessibility.
3. Remove `/Applications/Zerm.app`.
4. Re-add `/Applications/Zerm.app`.
5. Reopen Zerm.

The dashboard setup diagnostics should report app signing, stable TCC identity, Accessibility trust, auto-paste readiness, and last insertion status separately.

## Ollama Trust

- macOS: verify official app signature/team where possible.
- Windows: verify Authenticode signer where possible.
- Linux: existing local Ollama listeners are treated as unverified unless explicitly allowed by the user.
- Installer downloads are bounded and hash/signature checked where supported.

Related: [[Zerm Runtime Privacy Model]], [[Zerm Auto Paste]]
