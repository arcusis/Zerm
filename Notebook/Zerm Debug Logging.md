# Zerm Debug Logging

Field reports of "mic not picked up / nothing transcribed" cannot be diagnosed from unified logging: `.debug`/`.info` aren't persisted, and `OSLogStore(scope: .system)` (used by `LogExporter`) is unreliable on user machines. Zerm therefore has an app-owned debug log users can enable and send us.

## How it works

- Settings → Diagnostics → **Debug Logging** toggle (`DebugLoggingEnabled` default, registered in `AppDefaults`), with a "Show in Finder" reveal.
- `Zerm/Services/DebugLogger.swift` appends plain-text lines to `~/Library/Application Support/com.arcusis.zerm/Logs/zerm-debug.log`; rotates at 5 MB to `zerm-debug.old.log` (10 MB hard cap). Serial queue + FileHandle; `log()` is an autoclosure guarded by a cached enabled flag, safe from any thread **except** the real-time audio callback.
- The RT render callback only increments swift-atomics counters (callbacks, frames in/out, render/write errors + last OSStatus, buffer overflows); session peak/avg dB rides the existing `meterLock`. A ~1 Hz heartbeat (`Recorder.updateAudioMeter`) and a one-line **session summary** at `CoreAudioRecorder.stopRecording` flush them off-RT.
- Instrumented: device resolution (incl. `deviceID == 0`), device/format details, device-list changes and mid-recording switches, watchdog/auto-stop triggers, transcription result (char count only — never transcript content, no audio retained).

## Reading a field log

The session summary classifies most failures: `renderErrs > 0` → AudioUnitRender failing (last OSStatus included); `callbacks == 0` → unit never delivered (dead/wrong device); `peak ≈ -160 dB` with healthy callbacks → genuinely silent input (muted mic, or permission denied — macOS feeds silence); `writeErrs > 0` → file write problem; `permission status=denied` → TCC.

## Related fix

`ZermEngine.requestRecordPermission` previously always returned `true`. It now checks `AVCaptureDevice.authorizationStatus(for: .audio)`, prompts when `notDetermined`, and refuses to start with a "Microphone access denied" notification when denied — previously a denied user recorded silence and saw only "Nothing transcribed".

See [[Zerm Setup And Permissions]], [[Zerm Auto Stop Dictation]].
