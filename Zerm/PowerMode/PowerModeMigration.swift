import Foundation
import os

/// One-time repair of Power Mode data written while Power Modes froze global settings (#315).
///
/// Before 2.8.6 a Power Mode copied the global transcription model, language and AI provider
/// into itself when it was created, and every recording wrote those copies — plus the prompt and
/// three formatting fields that had no UI — back over the global settings. Two things are left
/// behind on disk:
///
/// 1. An interrupted session snapshot (`powerModeActiveSession.v1`). 2.8.5 restored it on the next
///    launch; this does the same once, because 2.8.6 no longer has sessions to restore.
/// 2. Configs full of frozen values. The heuristic that clears them:
///    - The three seeded configs (General, Code, Writing) never had a user-chosen model, language,
///      prompt, provider, AI model or formatting value, so all of those are cleared.
///    - For user configs the formatting fields had no UI, so a value equal to what the old
///      initializer wrote (off / keep / off) is cleared. `PowerModeConfig`'s decoder does this.
///    - A user config's model, language, prompt or provider that equals the current global value
///      is cleared: dictation behaves exactly as it does today, and now follows future changes.
///      A value that differs is kept, because it may be a choice made in the editor.
///    - A provider that only transcribes (ElevenLabs, Deepgram, …) is cleared; it cannot enhance.
///    - The legacy enhancement override becomes an output-mode override: "always off" is Instant,
///      "always on" keeps today's behaviour against the output mode and toggle in effect now.
///
/// Runs before the enhancement toggle is folded into `DictationOutputMode`, which needs the legacy
/// toggle this reads. `defaults` is injectable so tests never touch the real install.
enum PowerModeMigration {
    static let completionKey = "ZermPowerModeInheritMigrationVersion"
    static let legacySessionKey = "powerModeActiveSession.v1"

    static let seededGeneralID = UUID(uuidString: "D3A0F9E1-6C37-4813-9C2D-111111111111")!
    static let seededCodeID = UUID(uuidString: "D3A0F9E1-6C37-4813-9C2D-222222222222")!
    static let seededWritingID = UUID(uuidString: "D3A0F9E1-6C37-4813-9C2D-333333333333")!
    static let seededIDs: Set<UUID> = [seededGeneralID, seededCodeID, seededWritingID]

    private static let logger = Logger(subsystem: "com.arcusis.zerm", category: "PowerModeMigration")

    static func run(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: completionKey) < 1 else { return }
        restoreAbandonedSession(defaults: defaults)
        migrateStoredConfigurations(defaults: defaults)
        defaults.set(1, forKey: completionKey)
    }

    // MARK: - Abandoned session

    /// Writes an interrupted session's snapshot back to the global keys it came from.
    static func restoreAbandonedSession(defaults: UserDefaults) {
        guard let data = defaults.data(forKey: legacySessionKey) else { return }
        defer { defaults.removeObject(forKey: legacySessionKey) }
        guard let session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = session["originalState"] as? [String: Any] else { return }

        if let enabled = state["isEnhancementEnabled"] as? Bool {
            defaults.set(enabled, forKey: "isAIEnhancementEnabled")
        }
        if let screen = state["useScreenCaptureContext"] as? Bool {
            defaults.set(screen, forKey: "useScreenCaptureContext")
        }
        if let promptId = state["selectedPromptId"] as? String {
            defaults.set(promptId, forKey: "selectedPromptId")
        }
        if let provider = state["selectedAIProvider"] as? String {
            defaults.set(provider, forKey: "selectedAIProvider")
            if let model = state["selectedAIModel"] as? String, !model.isEmpty {
                defaults.set(model, forKey: "\(provider)SelectedModel")
                if provider == AIProvider.ollama.rawValue {
                    defaults.set(model, forKey: AIService.ollamaModelKey)
                }
            }
        }
        if let language = state["selectedLanguage"] as? String {
            defaults.set(language, forKey: LanguagePreference.defaultsKey)
        }
        if let modelName = state["transcriptionModelName"] as? String {
            defaults.set(modelName, forKey: "CurrentTranscriptionModel")
        }
        if let formatting = state["isTextFormattingEnabled"] as? Bool {
            defaults.set(formatting, forKey: "IsTextFormattingEnabled")
        }
        if let raw = state["punctuationCleanupMode"] as? String, let mode = PunctuationCleanupMode(rawValue: raw) {
            PunctuationCleanupMode.setCurrent(mode, in: defaults)
        } else if let removePunctuation = state["removePunctuation"] as? Bool {
            PunctuationCleanupMode.setCurrent(removePunctuation ? .removeAll : .keep, in: defaults)
        }
        if let lowercase = state["lowercaseTranscription"] as? Bool {
            defaults.set(lowercase, forKey: "LowercaseTranscription")
        }
        logger.notice("Restored the global settings of an interrupted Power Mode session")
    }

    // MARK: - Stored configurations

    /// The global values the frozen copies are compared against.
    struct Globals {
        var transcriptionModelName: String?
        var language: String
        var promptId: String?
        var aiProvider: String
        var aiModelForProvider: (String) -> String?
        var outputMode: DictationOutputMode
        var enhancementEnabled: Bool

        static func read(from defaults: UserDefaults) -> Globals {
            Globals(
                transcriptionModelName: defaults.string(forKey: "CurrentTranscriptionModel"),
                language: defaults.string(forKey: LanguagePreference.defaultsKey) ?? LanguagePreference.autoCode,
                promptId: defaults.string(forKey: "selectedPromptId"),
                aiProvider: defaults.string(forKey: "selectedAIProvider") ?? AIProvider.localLLM.rawValue,
                aiModelForProvider: { provider in
                    if provider == AIProvider.ollama.rawValue,
                       let model = defaults.string(forKey: AIService.ollamaModelKey), !model.isEmpty {
                        return model
                    }
                    if let model = defaults.string(forKey: "\(provider)SelectedModel"), !model.isEmpty {
                        return model
                    }
                    return AIProvider(rawValue: provider)?.defaultModel
                },
                outputMode: DictationOutputMode(rawValue: defaults.string(forKey: DictationOutputMode.storageKey) ?? "")
                    ?? .instantRefine,
                enhancementEnabled: defaults.object(forKey: "isAIEnhancementEnabled") as? Bool ?? true
            )
        }
    }

    static func migrateStoredConfigurations(defaults: UserDefaults) {
        guard let data = defaults.data(forKey: PowerModeManager.configKey),
              let configs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let migrated = migrate(configs, globals: .read(from: defaults))
        guard let newData = try? JSONSerialization.data(withJSONObject: migrated) else { return }
        defaults.set(newData, forKey: PowerModeManager.configKey)
        logger.notice("Cleared frozen settings from \(configs.count, privacy: .public) Power Mode configurations")
    }

    /// Operates on raw JSON so the result does not depend on how `PowerModeConfig` decodes
    /// legacy fields, and so it composes with other raw-JSON migrations of the same key.
    static func migrate(_ configs: [[String: Any]], globals: Globals) -> [[String: Any]] {
        configs.map { original in
            var config = original
            let isSeeded = (config["id"] as? String).flatMap(UUID.init(uuidString:)).map(seededIDs.contains) ?? false

            if config["outputMode"] == nil {
                let legacyOverride = config["enhancementOverride"] as? String
                    ?? ((config["isAIEnhancementEnabled"] as? Bool) == true ? "on" : "inherit")
                switch legacyOverride {
                case "off":
                    config["outputMode"] = DictationOutputMode.instant.rawValue
                case "on" where globals.outputMode != .instant && !globals.enhancementEnabled:
                    // The only case where "always on" changed anything: the toggle was off but
                    // the mode would have enhanced.
                    config["outputMode"] = globals.outputMode.rawValue
                default:
                    break
                }
            }
            config.removeValue(forKey: "enhancementOverride")

            if isSeeded {
                for key in ["selectedTranscriptionModelName", "selectedWhisperModel", "selectedLanguage",
                            "selectedPrompt", "selectedAIProvider", "selectedAIModel",
                            "isTextFormattingEnabled", "punctuationCleanupMode", "removePunctuation",
                            "lowercaseTranscription"] {
                    config.removeValue(forKey: key)
                }
                return config
            }

            if let model = config["selectedTranscriptionModelName"] as? String, model == globals.transcriptionModelName {
                config.removeValue(forKey: "selectedTranscriptionModelName")
            }
            if let language = config["selectedLanguage"] as? String, language == globals.language {
                config.removeValue(forKey: "selectedLanguage")
            }
            if let prompt = config["selectedPrompt"] as? String, prompt == globals.promptId {
                config.removeValue(forKey: "selectedPrompt")
            }
            if let provider = config["selectedAIProvider"] as? String {
                let isTranscriptionOnly = AIProvider(rawValue: provider)?.isTranscriptionOnly ?? true
                if isTranscriptionOnly || provider == globals.aiProvider {
                    config.removeValue(forKey: "selectedAIProvider")
                } else if let model = config["selectedAIModel"] as? String, model == globals.aiModelForProvider(provider) {
                    config.removeValue(forKey: "selectedAIModel")
                }
            }
            if config["selectedAIProvider"] == nil {
                config.removeValue(forKey: "selectedAIModel")
            }
            return config
        }
    }
}
