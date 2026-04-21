<p align="center">
  <img src="./assets/logo.png" alt="Zerm logo" width="120" height="120" />
</p>

<h1 align="center">Zerm</h1>

<p align="center">
  Local voice-to-clipboard for developers. Tap a key, speak, paste.
</p>

<p align="center">
  <a href="https://github.com/arcusis/Zerm/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/arcusis/Zerm/ci.yml?branch=Production&label=ci"></a>
  <a href="https://github.com/arcusis/Zerm/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/arcusis/Zerm?include_prereleases&label=release"></a>
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/github/license/arcusis/Zerm"></a>
  <a href="https://arcusis.github.io/Zerm/"><img alt="Website" src="https://img.shields.io/badge/website-arcusis.github.io%2FZerm-111111"></a>
</p>

Zerm is a native desktop app that turns speech into clean text without sending
your voice to a cloud service. It records from your microphone, transcribes with
Whisper on your machine, optionally reformats the transcript through your local
Ollama model, and writes the result to your clipboard.

It is built for people who use voice as an input method for coding agents,
Slack, email, notes, pull request reviews, and long-form writing.

## Contents

- [Features](#features)
- [Install](#install)
- [First-run Setup](#first-run-setup)
- [Usage](#usage)
- [Privacy And Security](#privacy-and-security)
- [Build From Source](#build-from-source)
- [Project Structure](#project-structure)
- [Verification](#verification)
- [Contributing](#contributing)
- [Release Process](#release-process)
- [Roadmap](#roadmap)
- [License](#license)

## Features

- **On-device transcription** with `whisper.cpp` through `whisper-rs`.
- **Local rewrite modes** through Ollama and Gemma 3: Off, Agent, Chat, and Pro.
- **Clipboard-first workflow**: record, process, copy, and optionally auto-paste on macOS.
- **Hotkey recording**: Right Option on macOS; Ctrl+Shift+Space on Windows/Linux.
- **Voice activity detection** to auto-stop after silence.
- **Custom vocabulary** for names, project terms, acronyms, and identifiers.
- **Private by default history**: history starts off and can be enabled explicitly.
- **First-run setup UI** for Whisper, Ollama, and the local model.
- **Cross-platform bundles** for macOS, Windows, and Linux through Tauri 2.

## Install

Download the latest build from the
[Releases](https://github.com/arcusis/Zerm/releases) page or the
[project website](https://arcusis.github.io/Zerm/).

| Platform | Package | Current hotkey |
| --- | --- | --- |
| macOS Apple Silicon | `.dmg` | Right Option |
| macOS Intel | `.dmg` | Right Option |
| Windows | `.msi` or `.exe` | Ctrl+Shift+Space |
| Linux | `.deb` or `.AppImage` | Ctrl+Shift+Space |

Stable macOS and Windows releases are expected to be signed. Linux release
artifacts are published with SHA-256 checksums instead of platform signing.
Prerelease builds may be unsigned while the project is still moving quickly.

## First-run Setup

The dashboard walks through setup when something is missing:

1. **Whisper model**: downloads the multilingual `ggml-small.bin` model into
   the app data directory.
2. **Ollama**: detects a trusted local Ollama listener, or offers install steps
   when Ollama is missing.
3. **Gemma 3 4B**: pulls the default local rewrite model through Ollama.

macOS also requires Accessibility permission for global modifier-key recording
and auto-paste. Auto-paste is currently macOS-only until Windows and Linux
paste synthesis exists. Microphone permission is requested by the operating
system on first use.

## Usage

1. Launch Zerm.
2. Press the hotkey to start recording.
3. Speak naturally.
4. Press the hotkey again or stop talking and let silence detection finish.
5. Paste the copied result wherever you were working.

Prompt modes:

| Mode | Output |
| --- | --- |
| Off | Raw transcript with conservative cleanup |
| Agent | A clear instruction for a coding agent |
| Chat | Short casual message |
| Pro | Polished long-form prose |

## Privacy And Security

Zerm is designed around local processing.

- No accounts.
- No telemetry.
- No hosted transcription service.
- No cloud LLM calls from Zerm.
- Dictation history is off by default.
- Clearing or disabling history also erases the backup state file.
- Local Ollama access is verified before transcripts are sent to
  `127.0.0.1:11434`; degraded local identity checks require explicit opt-in.

First-run setup does make network requests to download required model and
installer assets:

| Destination | Purpose |
| --- | --- |
| `huggingface.co` | Whisper model download |
| `api.github.com` / `github.com` | Ollama release metadata and installer assets |
| Ollama model registry | Gemma model pull through the local Ollama service |

Downloaded setup assets are bounded and hash/signature checked where the app can
verify them. Release builds are also checked by CI before publishing.

## Build From Source

Prerequisites:

- Node.js 22 or newer
- pnpm 10.33.0 through Corepack
- Rust stable
- Tauri system dependencies for your platform
- CMake
- Ollama, if you want local rewrite modes during development

macOS:

```sh
brew install cmake ollama
corepack enable
corepack prepare pnpm@10.33.0 --activate
pnpm install
pnpm tauri dev
```

Ubuntu 22.04+:

```sh
sudo apt-get update
sudo apt-get install -y \
  libwebkit2gtk-4.1-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev \
  libgtk-3-dev \
  libsoup-3.0-dev \
  libjavascriptcoregtk-4.1-dev \
  libasound2-dev \
  libxdo-dev \
  cmake \
  build-essential

corepack enable
corepack prepare pnpm@10.33.0 --activate
pnpm install
pnpm tauri dev
```

Build a bundle:

```sh
pnpm tauri build
```

## Project Structure

| Path | Purpose |
| --- | --- |
| `src-tauri/src/lib.rs` | Tauri commands, app lifecycle, setup, recording pipeline |
| `src-tauri/src/audio.rs` | Microphone capture and audio utilities |
| `src-tauri/src/whisper.rs` | Whisper model loading and transcription |
| `src-tauri/src/ollama.rs` | Local Ollama identity checks and rewrite requests |
| `src-tauri/src/state.rs` | Settings, history, stats, persistence |
| `dashboard.html` | Main dashboard markup |
| `src/dashboard.ts` | Dashboard behavior and setup flows |
| `src/styles.css` | App UI styling |
| `docs/` | GitHub Pages landing page |
| `assets/` | Repository-facing logo assets |

## Verification

Run the same checks used by CI:

```sh
pnpm typecheck
pnpm build
pnpm audit --prod
cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo check --manifest-path src-tauri/Cargo.toml --all-targets
cargo test --manifest-path src-tauri/Cargo.toml --lib
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets --all-features -- -D warnings
cargo audit --file src-tauri/Cargo.lock --deny warnings \
  --ignore RUSTSEC-2024-0370 \
  --ignore RUSTSEC-2024-0411 \
  --ignore RUSTSEC-2024-0412 \
  --ignore RUSTSEC-2024-0413 \
  --ignore RUSTSEC-2024-0414 \
  --ignore RUSTSEC-2024-0415 \
  --ignore RUSTSEC-2024-0416 \
  --ignore RUSTSEC-2024-0417 \
  --ignore RUSTSEC-2024-0418 \
  --ignore RUSTSEC-2024-0419 \
  --ignore RUSTSEC-2024-0420 \
  --ignore RUSTSEC-2024-0429 \
  --ignore RUSTSEC-2025-0057 \
  --ignore RUSTSEC-2025-0075 \
  --ignore RUSTSEC-2025-0080 \
  --ignore RUSTSEC-2025-0081 \
  --ignore RUSTSEC-2025-0098 \
  --ignore RUSTSEC-2025-0100 \
  --ignore RUSTSEC-2026-0097
```

`cargo fmt`, `cargo clippy`, and `cargo audit` require `rustfmt`,
`clippy`, and `cargo-audit` to be installed for your Rust toolchain.

```sh
rustup component add rustfmt clippy
cargo install cargo-audit --locked
```

The RustSec audit line matches the release workflow's current ignore list for
known advisories.

## Contributing

Issues and pull requests are welcome.

Before opening a PR:

1. Keep changes focused and explain the user-facing behavior.
2. Add or update tests for persistence, privacy, setup, or platform behavior.
3. Run the verification commands above.
4. Include screenshots or short recordings for UI changes.
5. Note any platform you could not test.

Good first areas:

- Platform-specific hotkey improvements.
- Linux and Windows setup recovery.
- Accessibility and keyboard navigation.
- Additional local prompt modes.
- Documentation for distro-specific Linux dependencies.

## Release Process

Releases are driven by tags.

```sh
git tag v0.1.0-alpha.16
git push origin v0.1.0-alpha.16
```

The release workflow runs preflight checks, creates a draft GitHub Release,
builds platform artifacts, uploads them, and publishes only after every matrix
job succeeds.

Stable tags such as `v0.1.0` require Apple and Windows signing secrets in the
GitHub repository. Linux release artifacts are published with SHA-256 checksums
rather than platform signing. Prerelease tags such as `v0.1.0-alpha.16` can
publish unsigned artifacts.

The website deploys separately from `docs/` on pushes to the `Production`
branch or through manual workflow dispatch.

## Roadmap

- Push-to-talk style modifier hooks for Windows and Linux.
- Faster streaming transcription and rewrite feedback.
- Optional encrypted history storage.
- User-defined prompt mode templates.
- Richer release provenance and public checksums.

## License

Zerm is released under the [MIT License](./LICENSE).

Built by [Arcusis](https://arcusis.com).
