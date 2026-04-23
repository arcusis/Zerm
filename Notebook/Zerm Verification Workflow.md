# Zerm Verification Workflow

Use these checks before pushing production changes when feasible.

## Local Checks

```sh
pnpm typecheck
pnpm build
cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo check --manifest-path src-tauri/Cargo.toml --all-targets
cargo test --manifest-path src-tauri/Cargo.toml --lib
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets --all-features -- -D warnings
```

For macOS local app replacement:

```sh
pnpm tauri build --bundles app
codesign --force --deep --options runtime \
  --entitlements src-tauri/Entitlements.plist \
  --sign 'Developer ID Application: Arcusis LTD (F9Z784RA6D)' \
  src-tauri/target/release/bundle/macos/Zerm.app
codesign --verify --deep --strict --verbose=2 src-tauri/target/release/bundle/macos/Zerm.app
codesign -d --entitlements :- src-tauri/target/release/bundle/macos/Zerm.app
```

Then stop the running Zerm process, back up `/Applications/Zerm.app`, copy the new bundle with `ditto`, verify `/Applications/Zerm.app`, and launch it.

Before declaring macOS recording fixed, verify all of these in `~/Library/Logs/Zerm/native-debug.log`:

- Right Option emits `hotkey event pressed=true backend=cgeventtap key_code=61`.
- Pill logs show `tauri_pill_isVisible=true` and `tauri_pill_isOnActiveSpace=Some(true)`.
- Capture starts with a real device name, for example `audio capture started device="MacBook Pro Microphone"`.
- Capture stops with nonzero `peak_rms`.
- Insertion succeeds in a real text field, for example `paste strategy success ... app_name=Notes`.

For native writing-layer regressions:

```sh
scripts/verify-native-writing-layer.sh
scripts/verify-native-writing-layer.sh --app /Applications/Zerm.app --strict-release
```

The default script mode is read-only. The interactive auto-paste self-test requires both `--run-autopaste-self-test` and `ZERM_VERIFY_ALLOW_INPUT=1`.

## Production Workflow

- Commit focused changes.
- Push to `origin Production`.
- For prerelease tags (`-alpha`, `-beta`, `-rc`), keep macOS signing enabled but allow `pnpm tauri build --skip-stapling` in CI so Apple notarization polling outages do not kill the release after signing succeeded.
- Stable releases should still require full signing credentials and should still block on notarization/stapling and Windows Authenticode verification.
- Do not spend time continuously monitoring CI unless explicitly requested. The user prefers to report CI failures back if they matter.

## Notebook Audit

After changing `Notebook/`, run:

```sh
python3 "$HOME/.codex/skills/notebook/scripts/notebook_audit.py" --repo-root . --vault Notebook
```

Related: [[Zerm Production History]]
