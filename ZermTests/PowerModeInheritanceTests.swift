import Foundation
import Testing
@testable import Zerm

/// Power Modes must inherit every setting they do not explicitly override (#315).
struct PowerModeInheritanceTests {

    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "com.arcusis.zerm.tests.powermode.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    private func decode(_ json: String) throws -> PowerModeConfig {
        try JSONDecoder().decode(PowerModeConfig.self, from: Data(json.utf8))
    }

    // MARK: - Codable

    @Test func newConfigOverridesNothing() {
        let config = PowerModeConfig(name: "Mail", emoji: "✉️")
        #expect(config.selectedTranscriptionModelName == nil)
        #expect(config.selectedLanguage == nil)
        #expect(config.outputMode == nil)
        #expect(config.selectedPrompt == nil)
        #expect(config.selectedAIProvider == nil)
        #expect(config.selectedAIModel == nil)
        #expect(config.contextAwareness == nil)
        #expect(config.isTextFormattingEnabled == nil)
        #expect(config.punctuationCleanupMode == nil)
        #expect(config.lowercaseTranscription == nil)
    }

    @Test func explicitOverridesSurviveARoundTrip() throws {
        let config = PowerModeConfig(
            name: "Terminal",
            emoji: "⌨️",
            selectedTranscriptionModelName: "parakeet-tdt-0.6b-v3",
            selectedLanguage: "he",
            outputMode: .instant,
            contextAwareness: false,
            isTextFormattingEnabled: false,
            punctuationCleanupMode: .keep,
            lowercaseTranscription: false
        )
        let decoded = try JSONDecoder().decode(PowerModeConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.selectedTranscriptionModelName == "parakeet-tdt-0.6b-v3")
        #expect(decoded.selectedLanguage == "he")
        #expect(decoded.outputMode == .instant)
        #expect(decoded.contextAwareness == false)
        #expect(decoded.isTextFormattingEnabled == false)
        #expect(decoded.punctuationCleanupMode == .keep)
        #expect(decoded.lowercaseTranscription == false)
    }

    @Test func inheritedValuesSurviveARoundTrip() throws {
        let config = PowerModeConfig(name: "General", emoji: "⚡")
        let decoded = try JSONDecoder().decode(PowerModeConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.outputMode == nil)
        #expect(decoded.contextAwareness == nil)
        #expect(decoded.isTextFormattingEnabled == nil)
        #expect(decoded.punctuationCleanupMode == nil)
        #expect(decoded.lowercaseTranscription == nil)
    }

    /// 2.8.5 decodes `isAIEnhancementEnabled` and `useScreenCapture` as required keys.
    @Test func encodingStaysReadableByTheLegacyDecoder() throws {
        let data = try JSONEncoder().encode(PowerModeConfig(name: "General", emoji: "⚡"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["isAIEnhancementEnabled"] as? Bool == false)
        #expect(json["useScreenCapture"] as? Bool == false)
    }

    @Test func legacyDefaultsDecodeAsInherit() throws {
        let config = try decode("""
        {"id":"\(UUID().uuidString)","name":"General","emoji":"⚡",
         "isAIEnhancementEnabled":false,"enhancementOverride":"inherit","useScreenCapture":false,
         "isTextFormattingEnabled":false,"punctuationCleanupMode":"keep","removePunctuation":false,
         "lowercaseTranscription":false}
        """)
        #expect(config.outputMode == nil)
        #expect(config.contextAwareness == nil)
        #expect(config.isTextFormattingEnabled == nil)
        #expect(config.punctuationCleanupMode == nil)
        #expect(config.lowercaseTranscription == nil)
    }

    @Test func legacyAlwaysOffBecomesInstant() throws {
        let config = try decode("""
        {"id":"\(UUID().uuidString)","name":"Terminal","emoji":"⌨️",
         "isAIEnhancementEnabled":false,"enhancementOverride":"off","useScreenCapture":true}
        """)
        #expect(config.outputMode == .instant)
        #expect(config.contextAwareness == true)
    }

    /// An imported 2.8.5 file cannot say what "always on" meant; it must never turn AI on.
    @Test func legacyAlwaysOnDecodesAsInherit() throws {
        let config = try decode("""
        {"id":"\(UUID().uuidString)","name":"Mail","emoji":"✉️",
         "isAIEnhancementEnabled":true,"enhancementOverride":"on","useScreenCapture":false}
        """)
        #expect(config.outputMode == nil)
        let boolOnly = try decode("""
        {"id":"\(UUID().uuidString)","name":"Mail","emoji":"✉️",
         "isAIEnhancementEnabled":true,"useScreenCapture":false}
        """)
        #expect(boolOnly.outputMode == nil)
    }

    // MARK: - Migration

    private func globals(
        model: String? = "parakeet-tdt-0.6b-v3",
        language: String = "auto",
        prompt: String? = PredefinedPrompts.defaultPromptId.uuidString,
        provider: String = "OpenAI",
        mode: DictationOutputMode = .instantRefine,
        enabled: Bool = true
    ) -> PowerModeMigration.Globals {
        PowerModeMigration.Globals(
            transcriptionModelName: model,
            language: language,
            promptId: prompt,
            aiProvider: provider,
            aiModelForProvider: { $0 == "OpenAI" ? "gpt-5.4" : nil },
            outputMode: mode,
            enhancementEnabled: enabled
        )
    }

    /// Migrates legacy dictionaries and decodes the result the way `PowerModeManager` loads it.
    private func migrateAndDecode(
        _ legacy: [[String: Any]],
        globals: PowerModeMigration.Globals
    ) throws -> [PowerModeConfig] {
        let migrated = PowerModeMigration.migrate(legacy, globals: globals)
        let data = try JSONSerialization.data(withJSONObject: migrated)
        let decoded = try JSONDecoder().decode([PowerModeConfig].self, from: data)
        // Saving and loading again must not change anything.
        let reloaded = try JSONDecoder().decode([PowerModeConfig].self, from: JSONEncoder().encode(decoded))
        for (first, second) in zip(decoded, reloaded) {
            #expect(first.outputMode == second.outputMode)
            #expect(first.contextAwareness == second.contextAwareness)
            #expect(first.selectedAIProvider == second.selectedAIProvider)
        }
        return decoded
    }

    /// What 2.8.5 wrote when it seeded General, Code and Writing with the global model frozen in.
    private func legacySeed(_ id: UUID) -> [String: Any] {
        [
            "id": id.uuidString, "name": "General", "emoji": "⚡",
            "isAIEnhancementEnabled": false, "enhancementOverride": "inherit",
            "selectedPrompt": PredefinedPrompts.defaultPromptId.uuidString,
            "selectedLanguage": "en", "selectedTranscriptionModelName": "parakeet-tdt-0.6b-v3",
            "selectedAIProvider": "OpenAI", "useScreenCapture": false,
            "isTextFormattingEnabled": false, "punctuationCleanupMode": "keep",
            "removePunctuation": false, "lowercaseTranscription": false, "isDefault": true
        ]
    }

    @Test func seededConfigsInheritWhatSeedingWrote() throws {
        for id in PowerModeMigration.seededIDs {
            let config = try #require(try migrateAndDecode([legacySeed(id)], globals: globals(prompt: nil)).first)
            #expect(config.selectedTranscriptionModelName == nil)
            #expect(config.selectedLanguage == nil)
            #expect(config.selectedPrompt == nil)
            #expect(config.selectedAIProvider == nil)
            #expect(config.selectedAIModel == nil)
            #expect(config.outputMode == nil)
            #expect(config.contextAwareness == nil)
            #expect(config.isTextFormattingEnabled == nil)
            #expect(config.punctuationCleanupMode == nil)
            #expect(config.lowercaseTranscription == nil)
            #expect(config.isDefault)
        }
    }

    /// 2.8.5 let users edit the seeded configs; those edits survive.
    @Test func editedSeededConfigsKeepTheUsersChoices() throws {
        var edited = legacySeed(PowerModeMigration.seededCodeID)
        edited["selectedPrompt"] = PredefinedPrompts.codingPromptId.uuidString
        edited["selectedLanguage"] = "he"
        edited["selectedTranscriptionModelName"] = "ggml-large-v3-turbo"
        edited["selectedAIProvider"] = "Anthropic"
        edited["selectedAIModel"] = "claude-haiku-4-5"
        edited["enhancementOverride"] = "off"
        edited["punctuationCleanupMode"] = "removeTrailingPeriod"

        let config = try #require(try migrateAndDecode([edited], globals: globals()).first)
        #expect(config.selectedPrompt == PredefinedPrompts.codingPromptId.uuidString)
        #expect(config.selectedLanguage == "he")
        #expect(config.selectedTranscriptionModelName == "ggml-large-v3-turbo")
        #expect(config.selectedAIProvider == "Anthropic")
        #expect(config.selectedAIModel == "claude-haiku-4-5")
        #expect(config.outputMode == .instant)
        #expect(config.punctuationCleanupMode == .removeTrailingPeriod)
    }

    @Test func userConfigsDropValuesEqualToTheGlobalSetting() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString, "name": "Slack", "emoji": "💬",
            "isAIEnhancementEnabled": false, "useScreenCapture": false,
            "selectedTranscriptionModelName": "parakeet-tdt-0.6b-v3",
            "selectedLanguage": "auto",
            "selectedPrompt": PredefinedPrompts.defaultPromptId.uuidString,
            "selectedAIProvider": "OpenAI", "selectedAIModel": "gpt-5.4",
            "isTextFormattingEnabled": false, "punctuationCleanupMode": "keep", "lowercaseTranscription": false
        ]
        let config = try #require(try migrateAndDecode([legacy], globals: globals()).first)
        #expect(config.selectedTranscriptionModelName == nil)
        #expect(config.selectedLanguage == nil)
        #expect(config.selectedPrompt == nil)
        #expect(config.selectedAIProvider == nil)
        #expect(config.selectedAIModel == nil)
        #expect(config.outputMode == nil)
        #expect(config.isTextFormattingEnabled == nil)
    }

    @Test func userConfigsKeepValuesThatDifferFromTheGlobalSetting() throws {
        let chatPrompt = PredefinedPrompts.chatPromptId.uuidString
        let legacy: [String: Any] = [
            "id": UUID().uuidString, "name": "Mail", "emoji": "✉️",
            "isAIEnhancementEnabled": false, "useScreenCapture": true,
            "selectedTranscriptionModelName": "ggml-large-v3-turbo",
            "selectedLanguage": "he",
            "selectedPrompt": chatPrompt,
            "selectedAIProvider": "Anthropic", "selectedAIModel": "claude-haiku-4-5",
            "lowercaseTranscription": true
        ]
        let config = try #require(try migrateAndDecode([legacy], globals: globals()).first)
        #expect(config.selectedTranscriptionModelName == "ggml-large-v3-turbo")
        #expect(config.selectedLanguage == "he")
        #expect(config.selectedPrompt == chatPrompt)
        #expect(config.selectedAIProvider == "Anthropic")
        #expect(config.selectedAIModel == "claude-haiku-4-5")
        #expect(config.contextAwareness == true)
        #expect(config.lowercaseTranscription == true)
    }

    @Test func transcriptionOnlyProvidersAreCleared() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString, "name": "Notes", "emoji": "📝",
            "isAIEnhancementEnabled": false, "useScreenCapture": false,
            "selectedAIProvider": "ElevenLabs", "selectedAIModel": "scribe_v1"
        ]
        let config = try #require(try migrateAndDecode([legacy], globals: globals()).first)
        #expect(config.selectedAIProvider == nil)
        #expect(config.selectedAIModel == nil)
    }

    /// 2.8.5 stored the Read Aloud model's name for On-Device and never used it.
    @Test func onDeviceModelNamesAreCleared() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString, "name": "Notes", "emoji": "📝",
            "isAIEnhancementEnabled": false, "useScreenCapture": false,
            "selectedAIProvider": "On-Device", "selectedAIModel": "Gemma 3 1B"
        ]
        let config = try #require(try migrateAndDecode([legacy], globals: globals()).first)
        #expect(config.selectedAIProvider == "On-Device")
        #expect(config.selectedAIModel == nil)
    }

    /// "Always on" only did something while the global toggle was off; that behaviour is kept as an
    /// explicit output mode. Otherwise it inherits — it must never switch an app to Refine, or send
    /// an Instant user's dictation to a cloud provider.
    @Test func legacyAlwaysOnKeepsTodaysBehaviour() throws {
        let alwaysOn: [String: Any] = [
            "id": UUID().uuidString, "name": "Mail", "emoji": "✉️",
            "isAIEnhancementEnabled": true, "enhancementOverride": "on", "useScreenCapture": false,
            "selectedAIProvider": "Anthropic", "selectedPrompt": PredefinedPrompts.chatPromptId.uuidString
        ]
        let toggleOff = try migrateAndDecode([alwaysOn], globals: globals(mode: .enhanced, enabled: false))
        #expect(toggleOff.first?.outputMode == .enhanced)

        let globalEnhanced = try migrateAndDecode([alwaysOn], globals: globals(mode: .enhanced, enabled: true))
        #expect(globalEnhanced.first?.outputMode == nil)
        #expect(globalEnhanced.first?.configuredOrGlobal(.enhanced) == .enhanced)

        let globalInstant = try migrateAndDecode([alwaysOn], globals: globals(mode: .instant, enabled: false))
        #expect(globalInstant.first?.outputMode == nil)
        #expect(globalInstant.first?.configuredOrGlobal(.instant) == .instant)

        // Without the legacy override key at all, only the bool.
        var boolOnly = alwaysOn
        boolOnly.removeValue(forKey: "enhancementOverride")
        let boolOnlyDecoded = try migrateAndDecode([boolOnly], globals: globals(mode: .instantRefine, enabled: true))
        #expect(boolOnlyDecoded.first?.outputMode == nil)
    }

    @Test func alreadyMigratedConfigsAreLeftAlone() throws {
        let encoded = try JSONEncoder().encode([PowerModeConfig(name: "Mail", emoji: "✉️", selectedLanguage: "auto", outputMode: .enhanced)])
        let current = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let config = try #require(try migrateAndDecode(current, globals: globals()).first)
        #expect(config.outputMode == .enhanced)
        #expect(config.selectedLanguage == "auto")
    }

    /// An enabled 2.8.5 Power Mode forced formatting off, so that is what the user actually got.
    @Test func formattingStaysOffWhenAPowerModeForcedItOff() throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "IsTextFormattingEnabled")
        let seed = legacySeed(PowerModeMigration.seededGeneralID)
        defaults.set(try JSONSerialization.data(withJSONObject: [seed]), forKey: PowerModeManager.configKey)

        PowerModeMigration.run(defaults: defaults)

        #expect(defaults.object(forKey: "IsTextFormattingEnabled") as? Bool == false)
        let data = try #require(defaults.data(forKey: PowerModeManager.configKey))
        #expect(try JSONDecoder().decode([PowerModeConfig].self, from: data).first?.isTextFormattingEnabled == nil)
    }

    @Test func formattingIsUntouchedWhenNoPowerModeWasEnabled() throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "IsTextFormattingEnabled")
        var disabled = legacySeed(PowerModeMigration.seededGeneralID)
        disabled["isEnabled"] = false
        defaults.set(try JSONSerialization.data(withJSONObject: [disabled]), forKey: PowerModeManager.configKey)

        PowerModeMigration.run(defaults: defaults)
        #expect(defaults.bool(forKey: "IsTextFormattingEnabled"))

        let noConfigs = isolatedDefaults("noConfigs")
        noConfigs.set(true, forKey: "IsTextFormattingEnabled")
        PowerModeMigration.run(defaults: noConfigs)
        #expect(noConfigs.bool(forKey: "IsTextFormattingEnabled"))
    }

    @Test func migrationRunsOnceAgainstStoredConfigurations() throws {
        let defaults = isolatedDefaults()
        defaults.set("parakeet-tdt-0.6b-v3", forKey: "CurrentTranscriptionModel")
        let seed = legacySeed(PowerModeMigration.seededGeneralID)
        defaults.set(try JSONSerialization.data(withJSONObject: [seed]), forKey: PowerModeManager.configKey)

        PowerModeMigration.run(defaults: defaults)
        let data = try #require(defaults.data(forKey: PowerModeManager.configKey))
        let config = try #require(try JSONDecoder().decode([PowerModeConfig].self, from: data).first)
        #expect(config.selectedTranscriptionModelName == nil)
        #expect(defaults.integer(forKey: PowerModeMigration.completionKey) == 1)

        // A later explicit override must not be cleared by a second launch.
        var edited = config
        edited.selectedTranscriptionModelName = "parakeet-tdt-0.6b-v3"
        defaults.set(try JSONEncoder().encode([edited]), forKey: PowerModeManager.configKey)
        PowerModeMigration.run(defaults: defaults)
        let again = try #require(defaults.data(forKey: PowerModeManager.configKey))
        #expect(try JSONDecoder().decode([PowerModeConfig].self, from: again).first?.selectedTranscriptionModelName == "parakeet-tdt-0.6b-v3")
    }

    @Test func abandonedSessionIsRestoredOnceAndRemoved() throws {
        let defaults = isolatedDefaults()
        defaults.set("ggml-large-v3-turbo", forKey: "CurrentTranscriptionModel")
        defaults.set("en", forKey: "SelectedLanguage")
        let session: [String: Any] = [
            "id": UUID().uuidString,
            "startTime": 0,
            "originalState": [
                "isEnhancementEnabled": true,
                "useScreenCaptureContext": false,
                "selectedAIProvider": "Anthropic",
                "selectedAIModel": "claude-haiku-4-5",
                "selectedLanguage": "he",
                "transcriptionModelName": "parakeet-tdt-0.6b-v3",
                "isTextFormattingEnabled": true,
                "punctuationCleanupMode": "removeTrailingPeriod",
                "lowercaseTranscription": false
            ]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: session), forKey: PowerModeMigration.legacySessionKey)

        PowerModeMigration.run(defaults: defaults)

        #expect(defaults.string(forKey: "CurrentTranscriptionModel") == "parakeet-tdt-0.6b-v3")
        #expect(defaults.string(forKey: "SelectedLanguage") == "he")
        #expect(defaults.string(forKey: "selectedAIProvider") == "Anthropic")
        #expect(defaults.string(forKey: "AnthropicSelectedModel") == "claude-haiku-4-5")
        #expect(defaults.bool(forKey: "IsTextFormattingEnabled"))
        #expect(PunctuationCleanupMode.current(in: defaults) == .removeTrailingPeriod)
        #expect(defaults.data(forKey: PowerModeMigration.legacySessionKey) == nil)
    }
}

private extension PowerModeConfig {
    func configuredOrGlobal(_ global: DictationOutputMode) -> DictationOutputMode {
        outputMode ?? global
    }
}
