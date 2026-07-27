# Zerm Latency Budget

Measured 2026-07-27 on M4 Max, Debug build (Release is faster). Numbers are from the unified log, not estimates.

## Dictation start — at its floor

hotkey → `.recording` = **79–86 ms**

| step | cost |
|---|---|
| hotkey → `.starting` | ~10 ms |
| createAudioUnit | 1.1–5.7 ms |
| setInputDevice | 16.5–18.6 ms |
| configureFormats | 6.4–10.3 ms |
| createOutputFile | 0.3–0.6 ms |
| AudioUnitInitialize | 9.8 ms |
| **AudioOutputUnitStart** | **43.0 ms** |

`AudioOutputUnitStart` is the OS spinning up the microphone. It **cannot** be removed without holding the input stream open permanently, which lights the orange privacy indicator forever. **~45 ms is the floor.** Pre-warming through `AudioUnitInitialize` buys ~10 ms and is not worth it — don't re-litigate this.

## The two wins that actually mattered

1. **`MenuBarView` had `@State var launchAtLoginEnabled = LaunchAtLogin.isEnabled`** — `SMAppService.status`, a synchronous XPC round-trip (~300 ms), re-run on *every* App-body re-evaluation because `MenuBarExtra` sits in `ZermApp.body`. A `sample` caught 279/681 main-thread samples in it. Fixed via `LaunchAtLoginStore` (async cache). This alone was worth ~300 ms at record start **and ~400 ms after stop** — the post-stop gap went 270–449 ms → 20–42 ms.
2. **Whisper 120 s idle unload** — any dictation more than 2 min after the last paid a ~800 ms model reload. Now resident, released on `DispatchSource` memory pressure instead. Also removed `whisperModelManager.unloadModel()` from the main window's `onDisappear`: for a menu-bar app, "window closed" is the steady state.

## Verification lesson

`pgrep` returning nothing does **not** mean a clean exit — a crashed process is also gone. Compare the newest file in `~/Library/Logs/DiagnosticReports/` before and after. Three crashes this session were initially reported as passing because of weak checks.

Related: [[Zerm Native Runtime Teardown]], [[Zerm Known Follow Ups]]
