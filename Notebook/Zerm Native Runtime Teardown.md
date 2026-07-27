# Zerm Native Runtime Teardown

Zerm embeds three C/C++ ML runtimes — whisper.cpp/ggml (STT), sherpa-onnx/onnxruntime (Kokoro TTS), llama.cpp (Gemma). All three misbehave around **process exit**, and all three produced shipping crashes on 2026-07-27.

## The quit crash (SIGABRT) — fixed in 2.6.1

```
exit() → __cxa_finalize_ranges
  → ~vector<unique_ptr<ggml_metal_device>>   ← a GLOBAL inside whisper.framework
    → ggml_metal_device_free → ggml_metal_rsets_free (ggml-metal-device.m:612)
      → ggml_abort → abort()
```

The assertion fires because ggml's own `ggml_metal_rsets_init` block is *still spinning in a `usleep` loop* on a background queue (ggml-metal-device.m:597) while teardown runs.

**Dead end (tried, verified not to work):** releasing the `WhisperContext` in `applicationWillTerminate`. The Metal device lives in a library-level global vector, so freeing our context does not remove it — it still crashed.

**Fix:** `AppDelegate.applicationWillTerminate` flushes `UserDefaults` and calls `_exit(0)`, skipping static destruction entirely. Safe because transcripts are committed to SwiftData as they complete; nothing in that destructor chain is ours.

## The launch crash (EXC_BREAKPOINT) — fixed in 2.6.0

The XCTest host launches the whole app then immediately `exit()`s, racing C++ static destruction against an in-flight onnxruntime session construction. `ProcessLifecycle.isTerminating` gates prewarm entry; set when `XCTestCase` is present and on `applicationWillTerminate`. Nothing inside sherpa-onnx is cancellable once entered, so refusing to *start* is the only lever.

## The CloudKit launch crash — fixed in 2.6.0

`Zerm.entitlements` declares `iCloud.com.arcusis.zerm`, but entitlements are only *granted* by a provisioning-profile-backed signature. Ad-hoc/unsigned builds don't have it, and CoreData+CloudKit traps rather than degrading. `#if LOCAL_BUILD` only covered `make local`, not plain Debug or the test host. Now a runtime `SecTaskCopyValueForEntitlement` check decides.

## Rule of thumb

Any background task that enters onnxruntime/ggml/llama.cpp must check `ProcessLifecycle.isTerminating` first, and the app must never leave via plain `exit()`.

Related: [[Zerm Latency Budget]], [[Zerm Architecture]]
