import Foundation
import Testing
@testable import Zerm

struct TranscriptionCapabilityTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "zerm.tests.capabilities.\(UUID().uuidString)")!
    }

    private func cloudModel(_ name: String) throws -> CloudModel {
        try #require(CloudProviderRegistry.allProviders.flatMap(\.models).first { $0.name == name })
    }

    // MARK: - Catalog

    @Test func catalogContainsVerifiedIdsOnly() {
        let names = Set(CloudProviderRegistry.allProviders.flatMap(\.models).map(\.name))
        #expect(names == [
            "gpt-transcribe", "gemini-3.5-transcribe", "scribe_v2", "stt-async-v5",
            "universal-3-5-pro", "universal-2", "nova-3", "nova-3-medical",
            "whisper-large-v3-turbo", "whisper-large-v3", "voxtral-mini-2602",
            "speechmatics-enhanced", "solaria-1", "grok-stt"
        ])
    }

    @Test func everyProviderHasOneRecommendedModelAndCapabilities() {
        for provider in CloudProviderRegistry.allProviders {
            #expect(provider.models.filter(\.isRecommended).count == 1, "\(provider.providerKey)")
            for model in provider.models {
                #expect(model.capabilities.contains(.languageHint) || !model.isMultilingualModel || model.name == "nova-3-medical", "\(model.name)")
                #expect(model.capabilities.contains(.streaming) == model.supportsStreaming, "\(model.name)")
            }
        }
    }

    @Test func hebrewOptimizedModelsSupportHebrew() {
        let hebrewModels = CloudProviderRegistry.allProviders.flatMap(\.models).filter(\.isHebrewOptimized)
        #expect(Set(hebrewModels.map(\.name)) == ["stt-async-v5", "universal-3-5-pro", "gemini-3.5-transcribe"])
        for model in hebrewModels {
            #expect(model.supportedLanguages["he"] != nil, "\(model.name)")
        }
    }

    @Test func languageListsKeepLocalAndRegionalEntries() throws {
        let models = TranscriptionModelRegistry.models
        let parakeetV3 = try #require(models.first { $0.name == "parakeet-tdt-0.6b-v3" })
        #expect(parakeetV3.supportedLanguages.count == 26)
        #expect(parakeetV3.supportedLanguages["auto"] != nil && parakeetV3.supportedLanguages["uk"] != nil)

        for name in ["ivrit-large-v3-turbo", "ivrit-large-v3"] {
            let ivrit = try #require(models.first { $0.name == name })
            #expect(Set(ivrit.supportedLanguages.keys) == ["auto", "he", "en"], "\(name)")
        }

        let nova3 = try cloudModel("nova-3")
        #expect(nova3.supportedLanguages["pt-BR"] == "Portuguese (Brazil)")
        #expect(LanguageDictionary.all["pt-BR"] == nil)
    }

    @Test func localModelsDeclareCapabilities() {
        let whisper = WhisperModel(name: "ggml-large-v3-turbo", displayName: "Turbo", size: "1 GB", supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper), description: "", speed: 1, accuracy: 1, ramUsage: 1)
        #expect(whisper.capabilities == [.prompt, .vocabulary, .languageHint])

        let englishWhisper = WhisperModel(name: "ggml-base.en", displayName: "Base", size: "1 GB", supportedLanguages: ["en": "English"], description: "", speed: 1, accuracy: 1, ramUsage: 1)
        #expect(englishWhisper.capabilities == [.prompt, .vocabulary])

        let parakeet = FluidAudioModel(name: "parakeet", displayName: "Parakeet", description: "", size: "", speed: 1, accuracy: 1, ramUsage: 1, supportsStreaming: true, supportedLanguages: ["auto": "Auto-detect"])
        #expect(parakeet.capabilities == [.streaming])
    }

    // MARK: - Active path

    @Test func streamingPathDropsBatchOnlyPrompt() throws {
        let soniox = try cloudModel("stt-async-v5")
        let defaults = makeDefaults()
        #expect(soniox.activeCapabilities(defaults: defaults).contains(.streaming))
        #expect(!soniox.activeCapabilities(defaults: defaults).contains(.prompt))
        #expect(soniox.activeCapabilities(defaults: defaults).contains(.vocabulary))

        defaults.set(false, forKey: "streaming-enabled-stt-async-v5")
        #expect(soniox.activeCapabilities(defaults: defaults).contains(.prompt))
        #expect(!soniox.activeCapabilities(defaults: defaults).contains(.streaming))
    }

    // MARK: - Settings visibility

    @Test func outputFormatShownOnlyWhereAPromptIsSent() throws {
        let defaults = makeDefaults()
        let whisper = WhisperModel(name: "ggml-large-v3-turbo", displayName: "Turbo", size: "1 GB", supportedLanguages: ["en": "English", "he": "Hebrew"], description: "", speed: 1, accuracy: 1, ramUsage: 1)

        let local = ModelSettingsVisibility(model: whisper, defaults: defaults)
        #expect(local.showsOutputFormat)
        #expect(local.showsVoiceActivityDetection)
        #expect(local.showsPrewarm)
        #expect(!local.showsCloudTimeout)
        #expect(!local.showsLiveTextPreview)

        let openAI = ModelSettingsVisibility(model: try cloudModel("gpt-transcribe"), defaults: defaults)
        #expect(openAI.showsOutputFormat)
        #expect(openAI.showsCloudTimeout)
        #expect(!openAI.showsVoiceActivityDetection)

        for name in ["nova-3", "scribe_v2", "universal-3-5-pro", "voxtral-mini-2602", "gemini-3.5-transcribe", "grok-stt", "solaria-1", "speechmatics-enhanced"] {
            #expect(!ModelSettingsVisibility(model: try cloudModel(name), defaults: defaults).showsOutputFormat, "\(name)")
        }

        let streamingDeepgram = ModelSettingsVisibility(model: try cloudModel("nova-3"), defaults: defaults)
        #expect(streamingDeepgram.showsLiveTextPreview)

        let none = ModelSettingsVisibility(model: nil, defaults: defaults)
        #expect(!none.showsOutputFormat && !none.showsCloudTimeout && !none.showsVoiceActivityDetection)
    }

    @Test func customModelVisibilityFollowsLanguageFlag() {
        let multilingual = CustomCloudModel(name: "m", displayName: "M", description: "", apiEndpoint: "https://x/v1/audio/transcriptions", modelName: "whisper")
        let english = CustomCloudModel(name: "e", displayName: "E", description: "", apiEndpoint: "https://x/v1/audio/transcriptions", modelName: "whisper", isMultilingual: false)
        #expect(multilingual.capabilities.contains(.languageHint))
        #expect(!english.capabilities.contains(.languageHint))
        #expect(ModelSettingsVisibility(model: english).showsOutputFormat)
        #expect(ModelSettingsVisibility(model: english).showsCloudTimeout)
    }

    // MARK: - Request fields follow capabilities

    @Test func requestCarriesOnlySupportedFields() throws {
        let defaults = makeDefaults()
        defaults.set("he", forKey: LanguagePreference.defaultsKey)

        let openAI = CloudTranscriptionService.makeRequest(for: try cloudModel("gpt-transcribe"), audioData: Data(), fileName: "a.wav", apiKey: "k", vocabulary: ["Zerm"], timeout: 60, defaults: defaults)
        #expect(openAI.language == "he")
        #expect(openAI.prompt == "שלום, מה שלומך? נעים להכיר.")
        #expect(openAI.vocabulary == ["Zerm"])

        let deepgram = CloudTranscriptionService.makeRequest(for: try cloudModel("nova-3"), audioData: Data(), fileName: "a.wav", apiKey: "k", vocabulary: ["Zerm"], timeout: 60, defaults: defaults)
        #expect(deepgram.prompt == nil)
        #expect(deepgram.language == "he")
        #expect(deepgram.vocabulary == ["Zerm"])

        let gladia = CloudTranscriptionService.makeRequest(for: try cloudModel("solaria-1"), audioData: Data(), fileName: "a.wav", apiKey: "k", vocabulary: ["Zerm"], timeout: 60, defaults: defaults)
        #expect(gladia.vocabulary.isEmpty)

        let english = CustomCloudModel(name: "e", displayName: "E", description: "", apiEndpoint: "https://x/v1/audio/transcriptions", modelName: "whisper", isMultilingual: false)
        let custom = CloudTranscriptionService.makeRequest(for: english, audioData: Data(), fileName: "a.wav", apiKey: "k", vocabulary: [], timeout: 60, defaults: defaults)
        #expect(custom.language == nil)
    }

    @Test func autoDetectSendsNoSamplePrompt() throws {
        let defaults = makeDefaults()
        defaults.set("auto", forKey: LanguagePreference.defaultsKey)
        let request = CloudTranscriptionService.makeRequest(for: try cloudModel("gpt-transcribe"), audioData: Data(), fileName: "a.wav", apiKey: "k", vocabulary: [], timeout: 60, defaults: defaults)
        #expect(request.language == nil)
        #expect(request.prompt == nil)
    }

    // MARK: - Per-language prompt

    @Test func promptResolvesForRequestLanguage() {
        let defaults = makeDefaults()
        #expect(WhisperPrompt.resolvedPrompt(for: "he", defaults: defaults) == "שלום, מה שלומך? נעים להכיר.")
        #expect(!WhisperPrompt.resolvedPrompt(for: "he", defaults: defaults).hasPrefix(","))
        #expect(WhisperPrompt.resolvedPrompt(for: "en", defaults: defaults).hasPrefix("Hello"))
        #expect(WhisperPrompt.resolvedPrompt(for: "auto", defaults: defaults) == "")
        #expect(WhisperPrompt.resolvedPrompt(for: nil, defaults: defaults) == "")
        #expect(WhisperPrompt.resolvedPrompt(for: "xx", defaults: defaults) == "")

        defaults.set(["he": "טקסט לדוגמה.", "en": ""], forKey: "CustomLanguagePrompts")
        #expect(WhisperPrompt.resolvedPrompt(for: "he", defaults: defaults) == "טקסט לדוגמה.")
        #expect(WhisperPrompt.resolvedPrompt(for: "en", defaults: defaults).hasPrefix("Hello"))
    }

    // MARK: - Timeout

    @Test func timeoutDefaultsAndScalesWithAudioLength() {
        let defaults = makeDefaults()
        #expect(CloudTranscriptionSettings.configuredTimeout(defaults: defaults) == 60)
        #expect(CloudTranscriptionSettings.timeout(forAudioDuration: 10, defaults: defaults) == 60)
        #expect(CloudTranscriptionSettings.timeout(forAudioDuration: 3_600, defaults: defaults) == 1_830)
        #expect(CloudTranscriptionSettings.timeout(forAudioDuration: 100_000, defaults: defaults) == 10_800)

        defaults.set(300, forKey: CloudTranscriptionSettings.timeoutKey)
        #expect(CloudTranscriptionSettings.timeout(forAudioDuration: 10, defaults: defaults) == 300)
    }
}
