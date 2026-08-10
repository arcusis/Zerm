# Zerm Runtime Privacy Model

## What Data Leaves the Device

Zerm only sends data externally when the user has explicitly configured an external provider.

| Data | Sent where | Condition |
|------|-----------|-----------|
| Audio / transcribed text | Cloud transcription provider (OpenAI, Deepgram, etc.) | Only if cloud provider is selected |
| Meeting Room / Call audio | Selected cloud Dictation provider | Only when that model is selected and disclosed in meeting preflight |
| Enhancement prompt + transcribed text | AI enhancement provider (OpenAI, Gemini, Anthropic, etc.) | Only if enhancement is enabled + provider configured |
| Screen content | Configured enhancement provider | Only if "Context Awareness" is enabled; it leaves the Mac only when that provider is external |
| Clipboard text | Configured enhancement provider | Only if "Clipboard Context" is enabled; it leaves the Mac only when that provider is external |
| Selected text | Configured enhancement provider | Only if selected text capture is triggered; it leaves the Mac only when that provider is external |
| Product analytics / third-party telemetry | — | None |

## What Stays Local

- Audio files: `~/Library/Application Support/com.arcusis.zerm/Recordings/` (auto-cleaned by `AudioCleanupManager`)
- Meeting folders: `~/Library/Application Support/Zerm/Recordings/` (separate Room/Call tracks, manifest, recovery journal and sidecar; retained until the user deletes them)
- Transcription history: SwiftData store at `~/Library/Application Support/com.arcusis.zerm/default.store`
- Dictionary / word replacements: SwiftData store at `~/Library/Application Support/com.arcusis.zerm/dictionary.store` (optionally synced via iCloud CloudKit)
- API keys: shipped Release builds use the system Keychain and migrate verified legacy `LocalKeychain_*` values out of `UserDefaults`; unsigned/ad-hoc `DEBUG` developer builds intentionally use a local `UserDefaults` fallback
- Custom provider URL + model: UserDefaults (not sensitive)
- Meeting summaries: local Ollama only; the selected local model is snapshotted and the transcript is not sent through the cloud Enhancement provider
- Diagnostics: Apple MetricKit payloads delivered by macOS are logged locally; crash/hang diagnostic JSON is stored under the app's Application Support diagnostics directory and Zerm does not upload it

Meeting capture is explicit. Selected-application capture is the default; the user must separately choose the warned all-system-audio fallback. Browser process capture can include audio from other tabs or helper processes owned by that browser, and the preflight discloses this limitation.

## HTTP Cache Disabled

`URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)` in `Zerm.swift` init — API responses are never stored in `Cache.db`.

## Context Disclosure Status

Resolved in the current branch. Permission/onboarding and context-toggle copy states that captured screen or clipboard text is not persisted by Zerm but is included in enhancement requests and can be sent to the configured provider; choosing an on-device provider keeps it on the Mac. The published contextual-awareness documentation separately describes the same provider boundary. English and Hebrew in-app strings are cataloged.

Related: [[Zerm Meeting Recording]], [[Zerm Setup And Permissions]], [[Zerm Overview]]
