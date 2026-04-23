# Zerm Setup And Permissions

Zerm setup covers model availability, local Ollama availability/trust, and platform input permissions.

## Setup Sequence

1. Whisper model: download `ggml-small.bin` into app data and load it.
2. macOS Accessibility permission: required for modifier-key recording and auto-paste.
3. macOS Microphone permission and entitlement: required before CPAL capture can produce usable samples.
4. Ollama: install official local app when missing, or allow user opt-in to an existing local service.
5. Gemma model: pull the configured local model through Ollama.

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

## macOS Microphone

Microphone trust has two independent requirements:

- User approval in System Settings -> Privacy and Security -> Microphone for `/Applications/Zerm.app`.
- The signed app must carry the hardened-runtime entitlement `com.apple.security.device.audio-input`.

Do not assume the System Settings toggle proves capture will work. A Developer ID signed app without the audio-input entitlement can show as enabled in Microphone settings while AVFoundation reports denied or CPAL opens a stream that only yields silence.

Production and local signed installs must include `src-tauri/Entitlements.plist` when signing:

```sh
codesign --force --deep --options runtime \
  --entitlements src-tauri/Entitlements.plist \
  --sign 'Developer ID Application: Arcusis LTD (F9Z784RA6D)' \
  /Applications/Zerm.app
```

If macOS has cached a stale Microphone decision for an older unentitled build, reset it after installing the entitled build:

```sh
tccutil reset Microphone com.arcusis.zerm
```

The recorder diagnostics should log `device`, `sample_format`, raw sample count, duration, and `peak_rms`. A healthy spoken capture should have nonzero `peak_rms`; values near `0.0000` indicate permission, device, mute, or input-level issues before STT.

## Ollama Trust

- macOS: verify official app signature/team where possible.
- Windows: verify Authenticode signer where possible.
- Linux: existing local Ollama listeners are treated as unverified unless explicitly allowed by the user.
- Installer downloads are bounded and hash/signature checked where supported.

Related: [[Zerm Runtime Privacy Model]], [[Zerm Auto Paste]], [[Zerm Verification Workflow]]
