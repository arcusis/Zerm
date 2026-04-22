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
codesign --force --deep --sign - --identifier com.arcusis.zerm src-tauri/target/release/bundle/macos/Zerm.app
codesign --verify --deep --strict --verbose=2 src-tauri/target/release/bundle/macos/Zerm.app
```

Then stop the running Zerm process, back up `/Applications/Zerm.app`, copy the new bundle with `ditto`, verify `/Applications/Zerm.app`, and launch it.

For native writing-layer regressions:

```sh
scripts/verify-native-writing-layer.sh
scripts/verify-native-writing-layer.sh --app /Applications/Zerm.app --strict-release
```

The default script mode is read-only. The interactive auto-paste self-test requires both `--run-autopaste-self-test` and `ZERM_VERIFY_ALLOW_INPUT=1`.

## Production Workflow

- Commit focused changes.
- Push to `origin Production`.
- Do not spend time continuously monitoring CI unless explicitly requested. The user prefers to report CI failures back if they matter.

## Notebook Audit

After changing `Notebook/`, run:

```sh
python3 "$HOME/.codex/skills/notebook/scripts/notebook_audit.py" --repo-root . --vault Notebook
```

Related: [[Zerm Production History]]
