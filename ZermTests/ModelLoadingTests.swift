import Foundation
import SwiftData
import Testing
@testable import Zerm

/// Counts context loads; contexts are empty, so nothing touches whisper.cpp.
@MainActor
private final class CountingContextLoader {
    private(set) var loadedPaths: [String] = []
    /// When set, loads stay suspended until `finishHeldLoads()`.
    var holdsLoads = false
    private var heldLoads: [CheckedContinuation<Void, Never>] = []

    func load(_ url: URL) async throws -> WhisperContext {
        loadedPaths.append(url.lastPathComponent)
        if holdsLoads {
            await withCheckedContinuation { heldLoads.append($0) }
        } else {
            // Suspend like a real load so concurrent requests overlap.
            await Task.yield()
        }
        return WhisperContext()
    }

    func finishHeldLoads() {
        heldLoads.forEach { $0.resume() }
        heldLoads = []
    }
}

@MainActor
struct ModelLoadingTests {

    private let modelsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zerm-model-loading-\(UUID().uuidString)", isDirectory: true)

    private func makeManager(_ loader: CountingContextLoader) -> WhisperModelManager {
        WhisperModelManager(modelsDirectory: modelsDirectory, contextLoader: { try await loader.load($0) })
    }

    private func modelFile(_ name: String) -> WhisperModelFile {
        WhisperModelFile(name: name, url: modelsDirectory.appendingPathComponent("\(name).bin"))
    }

    @Test func switchingWhisperModelsReleasesTheOldContextAndLoadsTheNewOneOnce() async throws {
        let loader = CountingContextLoader()
        let manager = makeManager(loader)
        let base = modelFile("ggml-base")
        let turbo = modelFile("ggml-large-v3-turbo")

        weak var baseContext: WhisperContext?
        baseContext = try await manager.loadModel(base)
        try await manager.loadModel(base)
        #expect(loader.loadedPaths == ["ggml-base.bin"])

        // Selecting another model frees the resident context before anything reloads.
        manager.releaseModel(otherThan: turbo.name)
        #expect(manager.whisperContext == nil)
        #expect(manager.loadedWhisperModel == nil)
        #expect(!manager.isModelLoaded)

        let turboContext = try await manager.loadModel(turbo)
        try await manager.loadModel(turbo)
        #expect(loader.loadedPaths == ["ggml-base.bin", "ggml-large-v3-turbo.bin"])
        #expect(manager.whisperContext === turboContext)
        #expect(manager.loadedWhisperModel?.name == turbo.name)
        #expect(manager.isModelLoaded)

        // The release task has run once the manager is idle again; nothing retains the old context.
        for _ in 0..<10 where baseContext != nil { await Task.yield() }
        #expect(baseContext == nil)
    }

    @Test func loadingADifferentModelDirectlyReplacesTheResidentOne() async throws {
        let loader = CountingContextLoader()
        let manager = makeManager(loader)

        let first = try await manager.loadModel(modelFile("ggml-base"))
        let second = try await manager.loadModel(modelFile("ggml-small"))

        #expect(first !== second)
        #expect(manager.whisperContext === second)
        #expect(manager.loadedWhisperModel?.name == "ggml-small")
        #expect(loader.loadedPaths.count == 2)
    }

    @Test func selectingTheResidentModelKeepsItLoaded() async throws {
        let loader = CountingContextLoader()
        let manager = makeManager(loader)
        let base = modelFile("ggml-base")

        let context = try await manager.loadModel(base)
        manager.releaseModel(otherThan: base.name)

        #expect(manager.whisperContext === context)
        #expect(loader.loadedPaths.count == 1)
    }

    @Test func concurrentRequestsForTheSameModelShareOneLoad() async throws {
        let loader = CountingContextLoader()
        let manager = makeManager(loader)
        let base = modelFile("ggml-base")

        async let first = manager.loadModel(base)
        async let second = manager.loadModel(base)
        let contexts = try await (first, second)

        #expect(contexts.0 === contexts.1)
        #expect(loader.loadedPaths == ["ggml-base.bin"])
    }

    @Test func aLoadSupersededByAModelSwitchIsDiscarded() async throws {
        let loader = CountingContextLoader()
        loader.holdsLoads = true
        let manager = makeManager(loader)

        let base = modelFile("ggml-base")
        let abandoned = Task { try await manager.loadModel(base) }
        while loader.loadedPaths.isEmpty { await Task.yield() }
        manager.releaseModel(otherThan: "parakeet-tdt-0.6b-v3")
        loader.finishHeldLoads()

        await #expect(throws: CancellationError.self) { _ = try await abandoned.value }
        #expect(manager.whisperContext == nil)
        #expect(manager.loadedWhisperModel == nil)
    }

    @Test func prewarmUsesTheEngineRegistry() throws {
        let container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let registry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: modelsDirectory,
            modelContext: ModelContext(container)
        )
        // No selected model, so the scheduled launch prewarm does nothing in the test host.
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: FluidAudioModelManager()
        )

        let prewarm = ModelPrewarmService(
            transcriptionModelManager: transcriptionModelManager,
            serviceRegistry: registry
        )

        #expect(prewarm.serviceRegistry === registry)
        #expect(prewarm.serviceRegistry.fluidAudioTranscriptionService === registry.fluidAudioTranscriptionService)
    }
}

struct ParakeetLanguageTests {

    @Test func parakeetV3IsMultilingualWithItsEuropeanLanguages() {
        let languages = LanguageDictionary.forProvider(isMultilingual: true, provider: .fluidAudio)
        #expect(languages.count == 26)
        #expect(languages["auto"] != nil)
        for code in ["en", "de", "fr", "es", "uk", "ru", "el", "mt"] {
            #expect(languages[code] != nil)
        }
        #expect(languages["he"] == nil)

        let model = FluidAudioModel(
            name: "parakeet-tdt-0.6b-v3", displayName: "Parakeet V3", description: "", size: "",
            speed: 1, accuracy: 1, ramUsage: 1, supportedLanguages: languages
        )
        #expect(model.isMultilingualModel)
    }

    @Test func englishOnlyParakeetIsNotMultilingual() {
        let languages = LanguageDictionary.forProvider(isMultilingual: false, provider: .fluidAudio)
        #expect(languages == ["en": "English"])

        let model = FluidAudioModel(
            name: "parakeet-tdt-0.6b-v2", displayName: "Parakeet V2", description: "", size: "",
            speed: 1, accuracy: 1, ramUsage: 1, supportedLanguages: languages
        )
        #expect(!model.isMultilingualModel)
    }
}
