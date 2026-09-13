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
        let picked = session.applying(RecorderChoices(powerMode: PowerModeConfig(
            name: "Mail",
            emoji: "✉️",
            selectedTranscriptionModelName: other.name,
            selectedLanguage: "en",
            outputMode: .enhanced
        )))
        #expect(picked.transcriptionModel.name == global.name)
        #expect(picked.languageCode == "he")
        #expect(picked.configuredOutputMode(global: .instant) == .enhanced)

        let toggled = picked.applying(RecorderChoices(outputMode: .instant))
        #expect(toggled.configuredOutputMode(global: .enhanced) == .instant)
    }

    // MARK: - Recording lifecycle

    /// A resolution that waits on a slow browser must not configure a recording that stopped, or
    /// was replaced by a newer one, while it waited.
    @Test func aSlowResolutionForAStoppedRecordingIsDiscarded() async {
        let tracker = DictationSessionTracker()
        let generation = tracker.begin(powerModeId: nil)
        let config = PowerModeConfig(name: "GitHub", emoji: "🐙")

        async let resolution = tracker.resolvePowerMode(for: generation, isLive: { true }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return config
        }
        tracker.stop()
        guard case .stale = await resolution else {
            Issue.record("a stopped recording must not be configured")
            return
        }
    }

    @Test func aSlowResolutionIsDiscardedWhenANewRecordingStarted() async {
        let tracker = DictationSessionTracker()
        let first = tracker.begin(powerModeId: nil)

        async let resolution = tracker.resolvePowerMode(for: first, isLive: { true }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return nil
        }
        let second = tracker.begin(powerModeId: nil)
        guard case .stale = await resolution else {
            Issue.record("the old recording must not configure the new one")
            return
        }
        #expect(second != first)
    }

    @Test func aResolutionForTheLiveRecordingIsUsed() async throws {
        let tracker = DictationSessionTracker()
        let generation = tracker.begin(powerModeId: nil)
        let config = PowerModeConfig(name: "Mail", emoji: "✉️")
        let resolution = await tracker.resolvePowerMode(for: generation, isLive: { true }) { config }
        guard case .resolved(let resolved) = resolution else {
            Issue.record("expected a resolution")
            return
        }
        #expect(resolved?.id == config.id)

        let notLive = await tracker.resolvePowerMode(for: generation, isLive: { false }) { config }
        guard case .stale = notLive else {
            Issue.record("a recording that is no longer recording is stale")
            return
        }
    }

    @Test func aConfigurationForAnEndedRecordingIsNotStored() throws {
        let tracker = DictationSessionTracker()
        let generation = tracker.begin(powerModeId: nil)
        tracker.stop()
        let session = DictationSessionConfiguration.resolve(
            powerMode: nil,
            globalModel: try #require(models.first),
            usableModels: models,
            globalLanguage: "auto",
            globalTextCleanup: globalCleanup
        )
        #expect(!tracker.setConfiguration(session, for: generation))
        #expect(tracker.configuration == nil)
    }

    @Test func aRecordingThatStoppedEarlyUsesTheFallbackConfiguration() throws {
        let tracker = DictationSessionTracker()
        _ = tracker.begin(powerModeId: nil)
        tracker.stop()
        let fallbackMode = PowerModeConfig(name: "Terminal", emoji: "⌨️", outputMode: .instant)
        let global = try #require(models.first)
        let taken = tracker.takeConfiguration {
            DictationSessionConfiguration.resolve(
                powerMode: fallbackMode,
                globalModel: global,
                usableModels: models,
                globalLanguage: "auto",
                globalTextCleanup: globalCleanup
            )
        }
        #expect(taken?.powerMode?.id == fallbackMode.id)
        #expect(taken?.clipboardContext == nil)
    }

    /// ⌘E and prompt picks in the recorder change this recording, never the Output setting.
    @Test func recorderChoicesApplyToTheRecordingOnly() throws {
        let globalBefore = DictationOutputMode.current
        let tracker = DictationSessionTracker()
        let generation = tracker.begin(powerModeId: nil)
        let terminal = PowerModeConfig(name: "Terminal", emoji: "⌨️", outputMode: .instant)
        let session = DictationSessionConfiguration.resolve(
            powerMode: terminal,
            globalModel: try #require(models.first),
            usableModels: models,
            globalLanguage: "auto",
            globalTextCleanup: globalCleanup
        )
        tracker.setConfiguration(session, for: generation)

        // The recorder shows the Power Mode's Instant, not the global Enhanced.
        #expect(tracker.effectiveOutputMode(global: .enhanced) == .instant)

        tracker.toggleEnhancement(global: .enhanced)
        #expect(tracker.effectiveOutputMode(global: .enhanced).usesEnhancement)
        tracker.toggleEnhancement(global: .enhanced)
        #expect(tracker.effectiveOutputMode(global: .enhanced) == .instant)

        tracker.selectPrompt(PredefinedPrompts.chatPromptId, global: .enhanced)
        #expect(tracker.effectiveOutputMode(global: .enhanced).usesEnhancement)
        #expect(tracker.effectivePromptID(global: PredefinedPrompts.defaultPromptId) == PredefinedPrompts.chatPromptId)

        let handedOff = try #require(tracker.takeConfiguration(fallback: { nil }))
        #expect(handedOff.configuredOutputMode(global: .enhanced).usesEnhancement)
        #expect(handedOff.enhancementOverrides.promptID == PredefinedPrompts.chatPromptId)
        #expect(DictationOutputMode.current == globalBefore)

        // Hand-off clears the choices for the next recording.
        #expect(tracker.choices == RecorderChoices())
        #expect(tracker.effectiveOutputMode(global: .enhanced) == .enhanced)
    }

    // MARK: - Bounded waits

    @Test func boundedWaitReturnsAFastValue() async {
        let task = Task<String?, Never> { "screen text" }
        let value = await BoundedWait.value(of: task, within: 1)
        #expect(value == .some("screen text"))
    }

    @Test func boundedWaitGivesUpOnSlowWork() async {
        let task = Task<String?, Never> {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return "too late"
        }
        let started = Date()
        let value = await BoundedWait.value(of: task, within: 0.1)
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 1)
        task.cancel()
    }

    @Test func boundedWaitStopsWhenCancelled() async {
        let task = Task<String?, Never> {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return "too late"
        }
        let cancelAt = Date().addingTimeInterval(0.05)
        let started = Date()
        let value = await BoundedWait.value(of: task, within: 5, isCancelled: { Date() > cancelAt })
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 1)
        task.cancel()
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
        DictationOutputMode.migrateLegacyEnhancementToggle(in: off, onDeviceEnhancementInstalled: true)
        #expect(DictationOutputMode.current(in: off) == .instant)
        #expect(DictationOutputMode.lastEnhancing(in: off) == .enhanced)
        #expect(off.object(forKey: "isAIEnhancementEnabled") == nil)
        #expect(off.object(forKey: "InstantTranscriptionMode") == nil)

        let on = isolatedDefaults("toggleOn")
        on.set(true, forKey: "isAIEnhancementEnabled")
        on.set(DictationOutputMode.instantRefine.rawValue, forKey: DictationOutputMode.storageKey)
        DictationOutputMode.migrateLegacyEnhancementToggle(in: on, onDeviceEnhancementInstalled: true)
        #expect(DictationOutputMode.current(in: on) == .instantRefine)
    }

    /// Untouched defaults without an enhancement model were silently Instant in 2.8.5; they stay
    /// Instant instead of warning on every launch, and ⌘E still returns to Instant + Refine.
    @Test func untouchedDefaultsWithoutAnOnDeviceModelBecomeInstant() {
        let fresh = isolatedDefaults("untouched")
        DictationOutputMode.migrateLegacyEnhancementToggle(in: fresh, onDeviceEnhancementInstalled: false)
        #expect(DictationOutputMode.current(in: fresh) == .instant)
        #expect(DictationOutputMode.lastEnhancing(in: fresh) == .instantRefine)

        let installed = isolatedDefaults("installed")
        DictationOutputMode.migrateLegacyEnhancementToggle(in: installed, onDeviceEnhancementInstalled: true)
        #expect(DictationOutputMode.current(in: installed) == .instantRefine)

        let cloud = isolatedDefaults("cloud")
        cloud.set(AIProvider.openAI.rawValue, forKey: "selectedAIProvider")
        DictationOutputMode.migrateLegacyEnhancementToggle(in: cloud, onDeviceEnhancementInstalled: false)
        #expect(DictationOutputMode.current(in: cloud) == .instantRefine)

        let enhanced = isolatedDefaults("enhancedChoice")
        enhanced.set(DictationOutputMode.enhanced.rawValue, forKey: DictationOutputMode.storageKey)
        DictationOutputMode.migrateLegacyEnhancementToggle(in: enhanced, onDeviceEnhancementInstalled: false)
        #expect(DictationOutputMode.current(in: enhanced) == .enhanced)
    }

    // MARK: - On-device model

    @Test func enhancementFallsBackToAnInstalledModelThatCanEnhance() throws {
        let gemma = LocalLLMModelManager.enhancementDefaultPackage
        let qwen = try #require(LocalLLMModelManager.packages(for: .enhancement).first { $0.fileName != gemma.fileName })
        let readingOnly = try #require(LocalLLMModelManager.packages.first { !$0.jobs.contains(.enhancement) })

        // A saved pick that is no longer on disk falls back to what is installed.
        #expect(LocalLLMModelManager.enhancementPackage(saved: qwen.fileName, reading: gemma, isDownloaded: { $0 == gemma }) == gemma)
        #expect(LocalLLMModelManager.enhancementPackage(saved: qwen.fileName, reading: gemma, isDownloaded: { $0 == qwen }) == qwen)
        // A Read Aloud model that cannot enhance is never borrowed.
        #expect(LocalLLMModelManager.enhancementPackage(saved: nil, reading: readingOnly, isDownloaded: { $0 == readingOnly }) == gemma)
        // Nothing installed: the pick, so settings can offer its download.
        #expect(LocalLLMModelManager.enhancementPackage(saved: qwen.fileName, reading: readingOnly, isDownloaded: { _ in false }) == qwen)
    }

    /// 2.8.5 Power Modes saved the Read Aloud model's name as the On-Device model.
    @Test func unknownOnDeviceModelNamesResolveToTheEnhancementModel() {
        let readingOnly = LocalLLMModelManager.packages.first { !$0.jobs.contains(.enhancement) }
        let resolved = LocalLLMModelManager.enhancementPackage(named: readingOnly?.displayName ?? "Unknown")
        #expect(resolved.jobs.contains(.enhancement))
        #expect(resolved == LocalLLMModelManager.package(for: .enhancement))
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
