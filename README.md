<p align="center">
  <img src="./assets/logo.png" alt="Zerm logo" width="120" height="120" />
</p>

<h1 align="center">Zerm</h1>

<p align="center">
  Native macOS voice dictation, transcription, context-aware prompting, and auto-paste.
</p>

<p align="center">
  <a href="https://github.com/arcusis/Zerm/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/arcusis/Zerm/ci.yml?branch=Production&label=ci"></a>
  <a href="https://github.com/arcusis/Zerm/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/arcusis/Zerm?include_prereleases&label=release"></a>
  <a href="./LICENSE"><img alt="License" src="https://img.shields.io/badge/license-GPLv3-blue"></a>
  <a href="https://arcusis.github.io/Zerm/"><img alt="Website" src="https://img.shields.io/badge/website-arcusis.github.io%2FZerm-111111"></a>
</p>

Zerm is a native macOS application for turning speech into clean text quickly.
It records from your microphone, transcribes with local and cloud-capable
engines, applies optional enhancement prompts, understands the active app or
website through Power Mode, and can paste the result directly at your cursor.

## Attribution

Zerm is based on the open-source project
[VoiceInk](https://github.com/Beingpax/VoiceInk) by
[Beingpax](https://github.com/Beingpax). VoiceInk provided the foundation for
the native macOS app architecture, dictation workflow, transcription pipeline,
Power Mode concept, model management, and many supporting services.

This repository is not trying to hide that lineage. Zerm is a modified GPLv3
derivative adapted for Arcusis branding, product direction, and ongoing
development. We keep the GPLv3 license, preserve attribution, and link back to
the upstream project so users and contributors can inspect the original work.

Additional attribution details are kept in [NOTICE](./NOTICE).

## Contents

- [Attribution](#attribution)
- [Features](#features)
- [Install](#install)
- [Requirements](#requirements)
- [Build From Source](#build-from-source)
- [Project Structure](#project-structure)
- [Privacy](#privacy)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Fast dictation workflow** for recording, transcribing, and inserting text.
- **Native macOS app** built in Swift and SwiftUI.
- **Global shortcuts** and push-to-talk style recording.
- **Auto-stop and auto-paste** so a dictation can finish and insert text with minimal friction.
- **Power Mode** to adapt prompts based on the active app, website, or workflow.
- **AI enhancement prompts** for cleanup, rewriting, assistant-style responses, and custom modes.
- **Local model support** through Whisper and FluidAudio-backed transcription paths.
- **Cloud transcription providers** for users who explicitly configure external services.
- **Personal dictionary** with vocabulary and word replacement support.
- **History and audio-file transcription** for reviewing or processing previous recordings.
- **macOS permissions flow** for microphone, Accessibility, screen context, and automation-related capabilities.

## Install

Download the latest macOS build from the
[Releases](https://github.com/arcusis/Zerm/releases) page or the
[project website](https://arcusis.github.io/Zerm/).

Zerm is currently focused on macOS.

## Requirements

- macOS 14.4 or later
- Microphone permission
- Accessibility permission for auto-paste and global insertion workflows
- Screen Recording permission only when screen/context-aware features are enabled

## Build From Source

The actively developed native app lives in [native-macos/](./native-macos).

Prerequisites:

- Xcode 16 or newer
- macOS 14.4 or newer
- Swift Package Manager dependencies resolved by Xcode

Build from the command line:

```sh
xcodebuild \
  -project native-macos/Zerm.xcodeproj \
  -scheme Zerm \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For detailed local build notes, see
[native-macos/BUILDING.md](./native-macos/BUILDING.md).

## Project Structure

| Path | Purpose |
| --- | --- |
| `native-macos/Zerm/` | Native Swift/SwiftUI macOS app |
| `native-macos/Zerm/Transcription/` | Transcription engines, providers, and processing pipeline |
| `native-macos/Zerm/PowerMode/` | App, URL, and context-aware prompt selection |
| `native-macos/Zerm/Views/` | SwiftUI application interface |
| `native-macos/Zerm/Services/` | App services, settings, dictionaries, model management, and integrations |
| `docs/` | GitHub Pages website |
| `NOTICE` | Upstream attribution and derivative-work notes |
| `LICENSE` | GPLv3 license text |

The older Tauri files remain in the repository for historical continuity while
the current product direction is the native macOS app.

## Privacy

Zerm is designed to make privacy boundaries explicit.

- Local transcription paths keep audio on the device.
- Cloud transcription and AI providers require user configuration before use.
- History and stored request payloads should be treated carefully because they may contain dictated text.
- Power Mode and screen-context features may require macOS permissions so Zerm can understand where the text is being inserted.

See [Notebook/Zerm Runtime Privacy Model.md](./Notebook/Zerm%20Runtime%20Privacy%20Model.md)
for project notes on runtime privacy behavior.

## Contributing

Issues and pull requests are welcome when they are aligned with the macOS app.

Before opening a PR:

1. Keep changes focused and describe the user-facing behavior.
2. Preserve GPLv3 attribution for VoiceInk-derived code.
3. Add or update tests for high-risk behavior.
4. Include screenshots or short recordings for UI changes.
5. Note any macOS permissions or signing behavior that could affect testing.

## License

Zerm is licensed under the
[GNU General Public License v3.0](./LICENSE).

Because Zerm is derived from [VoiceInk](https://github.com/Beingpax/VoiceInk),
the GPLv3 license and upstream attribution are part of the public project
identity. See [NOTICE](./NOTICE) for source attribution and modification notes.

Built by [Arcusis](https://arcusis.com), based on VoiceInk by Beingpax.
