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

    private func legacySeed(_ id: UUID) -> [String: Any] {
        [
            "id": id.uuidString, "name": "General", "emoji": "⚡",
            "isAIEnhancementEnabled": false, "enhancementOverride": "inherit",
            "selectedPrompt": PredefinedPrompts.defaultPromptId.uuidString,
            "selectedLanguage": "en", "selectedTranscriptionModelName": "ggml-large-v3-turbo",
            "selectedAIProvider": "On-Device", "useScreenCapture": false,
            "isTextFormattingEnabled": false, "punctuationCleanupMode": "keep",
            "removePunctuation": false, "lowercaseTranscription": false, "isDefault": true
        ]
    }

    @Test func seededConfigsInheritEverything() throws {
        for id in PowerModeMigration.seededIDs {
            let migrated = PowerModeMigration.migrate([legacySeed(id)], globals: globals())
            let data = try JSONSerialization.data(withJSONObject: migrated)
            let config = try #require(try JSONDecoder().decode([PowerModeConfig].self, from: data).first)
            #expect(config.selectedTranscriptionModelName == nil)
            #expect(config.selectedLanguage == nil)
            #expect(config.selectedPrompt == nil)
            #expect(config.selectedAIProvider == nil)
            #expect(config.selectedAIModel == nil)
            #expect(config.outputMode == nil)
            #expect(config.isTextFormattingEnabled == nil)
            #expect(config.punctuationCleanupMode == nil)
            #expect(config.lowercaseTranscription == nil)
            #expect(config.isDefault)
        }
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
        let migrated = PowerModeMigration.migrate([legacy], globals: globals())
        let data = try JSONSerialization.data(withJSONObject: migrated)
        let config = try #require(try JSONDecoder().decode([PowerModeConfig].self, from: data).first)
        #expect(config.selectedTranscriptionModelName == nil)
        #expect(config.selectedLanguage == nil)
        #expect(config.selectedPrompt == nil)
        #expect(config.selectedAIProvider == nil)
        #expect(config.selectedAIModel == nil)
        #expect(config.isTextFormattingEnabled == nil)
    }

    @Test func userConfigsKeepValuesThatDifferFromTheGlobalSetting() throws {
        let chatPrompt = PredefinedPrompts.chatPromptId.uuidString
        let legacy: [String: Any] = [
            "id": UUID().uuidString, "name": "Mail", "emoji": "✉️",
            "isAIEnhancementEnabled": true, "useScreenCapture": true,
            "selectedTranscriptionModelName": "ggml-large-v3-turbo",
            "selectedLanguage": "he",
            "selectedPrompt": chatPrompt,
            "selectedAIProvider": "Anthropic", "selectedAIModel": "claude-haiku-4-5",
            "lowercaseTranscription": true
        ]
        let migrated = PowerModeMigration.migrate([legacy], globals: globals())
        let data = try JSONSerialization.data(withJSONObject: migrated)
        let config = try #require(try JSONDecoder().decode([PowerModeConfig].self, from: data).first)
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
            "isAIEnhancementEnabled": true, "useScreenCapture": false,
            "selectedAIProvider": "ElevenLabs", "selectedAIModel": "scribe_v1"
        ]
        let migrated = PowerModeMigration.migrate([legacy], globals: globals())
        #expect(migrated.first?["selectedAIProvider"] == nil)
        #expect(migrated.first?["selectedAIModel"] == nil)
    }

    /// "Always on" only did something while the global toggle was off; that behaviour is kept
    /// as an explicit output mode, and otherwise it inherits.
    @Test func legacyAlwaysOnKeepsTodaysBehaviour() {
        let alwaysOn: [String: Any] = [
            "id": UUID().uuidString, "name": "Mail", "emoji": "✉️",
            "isAIEnhancementEnabled": true, "enhancementOverride": "on", "useScreenCapture": false
        ]
        let toggleOff = PowerModeMigration.migrate([alwaysOn], globals: globals(mode: .enhanced, enabled: false))
        #expect(toggleOff.first?["outputMode"] as? String == "enhanced")

        let toggleOn = PowerModeMigration.migrate([alwaysOn], globals: globals(mode: .enhanced, enabled: true))
        #expect(toggleOn.first?["outputMode"] == nil)

        let instant = PowerModeMigration.migrate([alwaysOn], globals: globals(mode: .instant, enabled: false))
        #expect(instant.first?["outputMode"] == nil)
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
