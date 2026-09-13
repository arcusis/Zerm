import Foundation
import Testing
@testable import Zerm

/// The per-recording configuration: resolved once, never written to global settings (#315).
@MainActor
struct DictationSessionTests {

    private var models: [any TranscriptionModel] {
        Array(TranscriptionModelRegistry.models.prefix(2))
    }

    private let globalCleanup = TextCleanupPreferences(formatsText: true, punctuation: .keep, lowercases: false)

    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "com.arcusis.zerm.tests.session.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test func aPowerModeWithoutOverridesInheritsEverything() throws {
        let global = try #require(models.first)
        let session = DictationSessionConfiguration.resolve(
            powerMode: PowerModeConfig(name: "General", emoji: "⚡", isDefault: true),
            globalModel: global,
            usableModels: models,
            globalLanguage: "he",
            globalTextCleanup: globalCleanup
        )
        #expect(session.transcriptionModel.name == global.name)
        #expect(session.languageCode == "he")
        #expect(session.textCleanup == globalCleanup)
        #expect(session.configuredOutputMode(global: .instantRefine) == .instantRefine)
        #expect(session.enhancementOverrides == EnhancementOverrides())
        #expect(session.usesScreenContext(global: true))
    }

    @Test func explicitOverridesApplyToTheSessionOnly() throws {
        let global = try #require(models.first)
        let other = try #require(models.last)
        let promptID = PredefinedPrompts.codingPromptId
        let config = PowerModeConfig(
            name: "Code",
            emoji: "⌘",
            selectedTranscriptionModelName: other.name,
            selectedLanguage: "en",
            outputMode: .instant,
            selectedPrompt: promptID.uuidString,
            selectedAIProvider: AIProvider.anthropic.rawValue,
            selectedAIModel: "claude-haiku-4-5",
            contextAwareness: false,
            lowercaseTranscription: true
        )
        let defaults = isolatedDefaults()
        defaults.set(global.name, forKey: "CurrentTranscriptionModel")

        let session = DictationSessionConfiguration.resolve(
            powerMode: config,
            globalModel: global,
            usableModels: models,
            globalLanguage: "auto",
            globalTextCleanup: globalCleanup
        )
        #expect(session.transcriptionModel.name == other.name)
        #expect(session.languageCode == "en")
        #expect(session.configuredOutputMode(global: .enhanced) == .instant)
        #expect(session.enhancementOverrides == EnhancementOverrides(promptID: promptID, provider: .anthropic, model: "claude-haiku-4-5"))
        #expect(!session.usesScreenContext(global: true))
        #expect(session.textCleanup == TextCleanupPreferences(formatsText: true, punctuation: .keep, lowercases: true))
        // Resolution reads globals; it never writes them.
        #expect(defaults.string(forKey: "CurrentTranscriptionModel") == global.name)
    }

    @Test func anUnusableOverrideModelFallsBackToTheGlobalModel() throws {
        let global = try #require(models.first)
        let session = DictationSessionConfiguration.resolve(
            powerMode: PowerModeConfig(name: "Old", emoji: "🕰", selectedTranscriptionModelName: "deleted-model"),
            globalModel: global,
            usableModels: models,
            globalLanguage: "auto",
            globalTextCleanup: globalCleanup
        )
        #expect(session.transcriptionModel.name == global.name)
    }

    @Test func transcriptionOnlyProviderOverridesAreIgnored() throws {
        let global = try #require(models.first)
        let session = DictationSessionConfiguration.resolve(
            powerMode: PowerModeConfig(name: "Notes", emoji: "📝", selectedAIProvider: AIProvider.deepgram.rawValue, selectedAIModel: "whisper-1"),
            globalModel: global,
            usableModels: models,
            globalLanguage: "auto",
            globalTextCleanup: globalCleanup
        )
        #expect(session.enhancementOverrides.provider == nil)
        #expect(session.enhancementOverrides.model == nil)
    }

    /// A Power Mode picked in the recorder changes enhancement but not the transcription model or
    /// language, which the live transcription session is already using.
    @Test func aPowerModePickedMidRecordingKeepsTheModelAndLanguage() throws {
        let global = try #require(models.first)
        let other = try #require(models.last)
        let session = DictationSessionConfiguration.resolve(
            powerMode: nil,
            globalModel: global,
            usableModels: models,
            globalLanguage: "he",
            globalTextCleanup: globalCleanup
        )
        let picked = session.replacingPowerMode(PowerModeConfig(
            name: "Mail",
            emoji: "✉️",
            selectedTranscriptionModelName: other.name,
            selectedLanguage: "en",
            outputMode: .enhanced
        ))
        #expect(picked.transcriptionModel.name == global.name)
        #expect(picked.languageCode == "he")
        #expect(picked.configuredOutputMode(global: .instant) == .enhanced)

        let toggled = picked.withExplicitOutputMode(.instant)
        #expect(toggled.configuredOutputMode(global: .enhanced) == .instant)
    }

    // MARK: - Browser URL matching

    private let appConfig = PowerModeConfig(name: "Browser", emoji: "🌐", appConfigs: [AppConfig(bundleIdentifier: "com.google.Chrome", appName: "Chrome")])
    private let githubConfig = PowerModeConfig(name: "GitHub", emoji: "🐙", urlConfigs: [URLConfig(url: "github.com")])

    @Test func aURLMatchInTimeConfiguresTheRecording() async {
        let resolved = await ActiveWindowService.configuration(
            appConfiguration: appConfig,
            configurations: [appConfig, githubConfig],
            waitLimit: 1,
            lookupURL: { "https://github.com/arcusis/Zerm" }
        )
        #expect(resolved?.id == githubConfig.id)
    }

    @Test func aLateURLMatchDoesNotChangeTheRecordingsConfiguration() async {
        let started = Date()
        let resolved = await ActiveWindowService.configuration(
            appConfiguration: appConfig,
            configurations: [appConfig, githubConfig],
            waitLimit: 0.05,
            lookupURL: {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "https://github.com/arcusis/Zerm"
            }
        )
        #expect(resolved?.id == appConfig.id)
        #expect(Date().timeIntervalSince(started) < 0.9)
    }

    @Test func aFailedURLLookupFallsBackToTheAppConfiguration() async {
        struct Unavailable: Error {}
        let resolved = await ActiveWindowService.configuration(
            appConfiguration: appConfig,
            configurations: [appConfig, githubConfig],
            waitLimit: 1,
            lookupURL: { throw Unavailable() }
        )
        #expect(resolved?.id == appConfig.id)
    }

    // MARK: - Settings migrations

    @Test func enhancementToggleFoldsIntoTheOutputMode() {
        let off = isolatedDefaults("toggleOff")
        off.set(false, forKey: "isAIEnhancementEnabled")
        off.set(true, forKey: "InstantTranscriptionMode")
        off.set(DictationOutputMode.enhanced.rawValue, forKey: DictationOutputMode.storageKey)
        DictationOutputMode.migrateLegacyEnhancementToggle(in: off)
        #expect(DictationOutputMode.current(in: off) == .instant)
        #expect(DictationOutputMode.lastEnhancing(in: off) == .enhanced)
        #expect(off.object(forKey: "isAIEnhancementEnabled") == nil)
        #expect(off.object(forKey: "InstantTranscriptionMode") == nil)

        let on = isolatedDefaults("toggleOn")
        on.set(true, forKey: "isAIEnhancementEnabled")
        on.set(DictationOutputMode.instantRefine.rawValue, forKey: DictationOutputMode.storageKey)
        DictationOutputMode.migrateLegacyEnhancementToggle(in: on)
        #expect(DictationOutputMode.current(in: on) == .instantRefine)
    }

    @Test func turningEnhancementBackOnReturnsToTheLastAIMode() {
        let defaults = isolatedDefaults()
        DictationOutputMode.setCurrent(.enhanced, in: defaults)
        DictationOutputMode.setCurrent(.instant, in: defaults)
        #expect(DictationOutputMode.lastEnhancing(in: defaults) == .enhanced)
        #expect(DictationOutputMode.lastEnhancing(in: isolatedDefaults("fresh")) == .instantRefine)
    }

    @Test func ollamaUsesOneModelKey() {
        let legacyOnly = isolatedDefaults("legacyOnly")
        legacyOnly.set("llama3.2", forKey: "OllamaSelectedModel")
        AIService.migrateOllamaModelKey(in: legacyOnly)
        #expect(legacyOnly.string(forKey: AIService.ollamaModelKey) == "llama3.2")
        #expect(legacyOnly.object(forKey: "OllamaSelectedModel") == nil)

        let both = isolatedDefaults("both")
        both.set("qwen3", forKey: AIService.ollamaModelKey)
        both.set("llama3.2", forKey: "OllamaSelectedModel")
        AIService.migrateOllamaModelKey(in: both)
        #expect(both.string(forKey: AIService.ollamaModelKey) == "qwen3")
        #expect(both.object(forKey: "OllamaSelectedModel") == nil)
    }
}
