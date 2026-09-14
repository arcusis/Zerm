# Zerm Dev Build Isolation

Development builds and the unit-test host run as **`com.arcusis.zerm.dev`**, not as the installed app. Added in 2.8.6 (`dedf25e`).

## Why

The XCTest host *is* the app: every `make test` launched Zerm under the production bundle id. It ran launch migrations against the real install's UserDefaults, stores and model folders. That is how retired model files were once deleted during development, and why the owner's Mac was declared "production, never build here".

## How it works

- `PRODUCT_BUNDLE_IDENTIFIER = "com.arcusis.zerm$(ZERM_BUNDLE_ID_SUFFIX)"`. The suffix is empty for Release, and `.dev` for `make test` and `make dev-app`.
- Every Application Support location goes through `AppStoragePaths`, keyed by bundle id:
  - `root` is `Application Support/<bundle id>`.
  - `legacyRoot` is `Application Support/Zerm`, or `Zerm (<bundle id>)` for dev builds.
- UserDefaults and TCC grants are per bundle id automatically. `KeychainService` uses UserDefaults under `DEBUG`, so keys are isolated too.
- The Sparkle updater never starts outside the production bundle, so a dev build can't update itself into the released app.
- `make dev-app` builds `.dev-build/Zerm Dev.app`. It is never installed to `/Applications`.

## Still shared

FluidAudio's model cache (`Application Support/FluidAudio/Models`) is global to the user. A dev build that deletes a Parakeet model deletes it for the installed app too.

## Hands-on testing on the owner's Mac

Allowed only with Zerm Dev:
- Give it hotkeys that differ from the installed app's (dictation `rightOption`, Read Aloud `leftOption`) before granting it Accessibility.
- No synthetic keystrokes into the owner's apps.

Related: [[Zerm Verification Workflow]]
