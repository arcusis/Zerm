# Zerm Runtime Privacy Model

## What Data Leaves the Device

Zerm only sends data externally when the user has explicitly configured an external provider.

| Data | Sent where | Condition |
|------|-----------|-----------|
| Audio / transcribed text | Cloud transcription provider (OpenAI, Deepgram, etc.) | Only if cloud provider is selected |
| Enhancement prompt + transcribed text | AI enhancement provider (OpenAI, Gemini, Anthropic, etc.) | Only if enhancement is enabled + provider configured |
| Screen content | Enhancement provider | Only if "Context Awareness" is enabled in Power Mode |
| Clipboard text | Enhancement provider | Only if "Clipboard Context" is enabled |
| Selected text | Enhancement provider | Only if selected text capture is triggered |
| No analytics, no telemetry | — | No background data collection |

## What Stays Local

- Audio files: `~/Library/Application Support/com.arcusis.zerm/Recordings/` (auto-cleaned by `AudioCleanupManager`)
- Transcription history: SwiftData store at `~/Library/Application Support/com.arcusis.zerm/default.store`
- Dictionary / word replacements: SwiftData store at `~/Library/Application Support/com.arcusis.zerm/dictionary.store` (optionally synced via iCloud CloudKit)
- API keys: `APIKeyManager` stores in the system Keychain (not UserDefaults)
- Custom provider URL + model: UserDefaults (not sensitive)

## HTTP Cache Disabled

`URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)` in `Zerm.swift` init — API responses are never stored in `Cache.db`.

## Known Privacy Gap (Z#177)

The in-app and website privacy section does not fully disclose that screen content and clipboard text may be sent to the AI provider when those features are enabled. Needs a documentation update.

Related: [[Zerm Setup And Permissions]], [[Zerm Overview]]
