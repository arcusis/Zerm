import Foundation
import SwiftData
import Testing
@testable import Zerm

/// Live text follows the model a dictation actually uses, which a Power Mode can override (#351).
@MainActor
struct LiveTextRoutingTests {

    private func cloudModel(_ name: String) throws -> CloudModel {
        try #require(CloudProviderRegistry.allProviders.flatMap(\.models).first { $0.name == name })
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "zerm.tests.live-text.\(UUID().uuidString)")!
    }

    // MARK: - Session model

    @Test func aUsablePowerModeModelReplacesAnUnusableGlobalModel() throws {
        let global = try cloudModel("gpt-transcribe")
        let streaming = try cloudModel("nova-3")
        let mode = PowerModeConfig(name: "Chat", emoji: "💬", selectedTranscriptionModelName: streaming.name)

        let model = DictationSessionConfiguration.sessionModel(powerMode: mode, globalModel: global, usableModels: [streaming])
        #expect(model?.name == streaming.name)
    }

    @Test func aPowerModeModelReplacesAMissingGlobalModel() throws {
        let streaming = try cloudModel("nova-3")
        let mode = PowerModeConfig(name: "Chat", emoji: "💬", selectedTranscriptionModelName: streaming.name)

        let model = DictationSessionConfiguration.sessionModel(powerMode: mode, globalModel: nil, usableModels: [streaming])
        #expect(model?.name == streaming.name)
    }

    @Test func anUnusablePowerModeModelFallsBackToAUsableGlobalModel() throws {
        let global = try cloudModel("gpt-transcribe")
        let mode = PowerModeConfig(name: "Chat", emoji: "💬", selectedTranscriptionModelName: "nova-3")

        let model = DictationSessionConfiguration.sessionModel(powerMode: mode, globalModel: global, usableModels: [global])
        #expect(model?.name == global.name)
    }

    @Test func noUsableModelResolvesToNil() throws {
        let global = try cloudModel("gpt-transcribe")
        let mode = PowerModeConfig(name: "Chat", emoji: "💬", selectedTranscriptionModelName: "nova-3")

        #expect(DictationSessionConfiguration.sessionModel(powerMode: mode, globalModel: global, usableModels: []) == nil)
        #expect(DictationSessionConfiguration.sessionModel(powerMode: nil, globalModel: nil, usableModels: [global]) == nil)
    }

    // MARK: - Settings visibility

    @Test func liveTextPreviewSettingShowsForAStreamingPowerModeModel() throws {
        let defaults = makeDefaults()
        let batchGlobal = try cloudModel("gpt-transcribe")
        let streaming = try cloudModel("nova-3")
        let modes = [PowerModeConfig(name: "Chat", emoji: "💬", selectedTranscriptionModelName: streaming.name)]

        let models = ModelSettingsVisibility.modelsInUse(global: batchGlobal, powerModes: modes, availableModels: [batchGlobal, streaming])
        #expect(models.map(\.name) == [batchGlobal.name, streaming.name])
        #expect(!ModelSettingsVisibility(model: batchGlobal, defaults: defaults).showsLiveTextPreview)
        #expect(ModelSettingsVisibility(models: models, defaults: defaults).showsLiveTextPreview)
    }

    @Test func disabledPowerModesDoNotWidenTheSettings() throws {
        let batchGlobal = try cloudModel("gpt-transcribe")
        let streaming = try cloudModel("nova-3")
        let modes = [PowerModeConfig(name: "Chat", emoji: "💬", selectedTranscriptionModelName: streaming.name, isEnabled: false)]

        let models = ModelSettingsVisibility.modelsInUse(global: batchGlobal, powerModes: modes, availableModels: [batchGlobal, streaming])
        #expect(models.map(\.name) == [batchGlobal.name])
    }

    // MARK: - Session routing

    private func makeRegistry() throws -> TranscriptionServiceRegistry {
        let container = try ModelContainer(for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("zerm-live-text-\(UUID().uuidString)")
        return TranscriptionServiceRegistry(
            modelProvider: WhisperModelManager(modelsDirectory: modelsDirectory),
            modelsDirectory: modelsDirectory,
            modelContext: ModelContext(container)
        )
    }

    @Test func streamingModelsGetAStreamingSession() throws {
        let registry = try makeRegistry()
        let defaults = makeDefaults()
        #expect(registry.createSession(for: try cloudModel("nova-3"), defaults: defaults) is StreamingTranscriptionSession)
        #expect(registry.createSession(for: try cloudModel("gpt-transcribe"), defaults: defaults) is FileTranscriptionSession)
    }

    @Test func turningRealTimeOffForAModelGivesItAFileSession() throws {
        let registry = try makeRegistry()
        let defaults = makeDefaults()
        defaults.set(false, forKey: "streaming-enabled-nova-3")
        #expect(registry.createSession(for: try cloudModel("nova-3"), defaults: defaults) is FileTranscriptionSession)
    }
}
