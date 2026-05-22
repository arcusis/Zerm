# Zerm Setup And Permissions

## Required macOS Permissions

| Permission | What needs it | How to grant |
|------------|--------------|--------------|
| Microphone | `CoreAudioRecorder` — audio capture | System Settings → Privacy → Microphone → Zerm |
| Accessibility | `CursorPaster` — CGEvent Cmd+V injection | System Settings → Privacy → Accessibility → Zerm |
| Screen Recording | `ScreenCaptureService` — Power Mode context capture | System Settings → Privacy → Screen Recording → Zerm |

## TCC Behaviour After Rebuild

macOS TCC (Transparency, Consent, Control) tracks apps by **bundle ID + code signature hash**.  
Ad-hoc signing changes the hash on every build, orphaning TCC grants.

**Fix:**
```bash
cd native-macos
make reset-permissions   # tccutil reset Accessibility + ScreenCapture for com.arcusis.zerm
```

Or manually:
```bash
tccutil reset Accessibility com.arcusis.zerm
tccutil reset ScreenCapture com.arcusis.zerm
```

## Launchpad Duplicate Icons

If multiple Zerm.app entries appear in Launchpad after rebuilds:
```bash
cd native-macos && make install
# make install already does: lsregister + Launchpad reset + tccutil reset
```

## Local Model Storage

Whisper models: `~/Library/Application Support/com.arcusis.zerm/WhisperModels/`  
FluidAudio (Parakeet) models: managed by `FluidAudioModelManager` (path handled by FluidAudio framework)  
whisper.cpp XCFramework: `$(HOME)/Zerm-Dependencies/whisper.cpp/build-apple/whisper.xcframework`

## First-Run Checklist

1. Open app → complete onboarding
2. Go to Settings → AI Models → download a local model (or configure cloud provider)
3. Grant Microphone when prompted
4. Grant Accessibility (for auto-paste)
5. Optionally grant Screen Recording (for Power Mode context)
6. Press the configured hotkey (default: Right Command) to test

Related: [[Zerm Auto Paste]], [[Zerm Runtime Privacy Model]]
