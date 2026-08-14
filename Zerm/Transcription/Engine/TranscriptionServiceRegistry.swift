import Foundation
import SwiftUI
import SwiftData
import os

@MainActor
class TranscriptionServiceRegistry {
    private weak var modelProvider: (any WhisperModelProvider)?
    private let modelsDirectory: URL
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TranscriptionServiceRegistry")

    private(set) lazy var localTranscriptionService = WhisperTranscriptionService(
        modelsDirectory: modelsDirectory,
        modelProvider: modelProvider,
        modelContext: modelContext
    )
    private(set) lazy var cloudTranscriptionService = CloudTranscriptionService(modelContext: modelContext)
    private(set) lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private(set) lazy var fluidAudioTranscriptionService = FluidAudioTranscriptionService()

    init(modelProvider: any WhisperModelProvider, modelsDirectory: URL, modelContext: ModelContext) {
        self.modelProvider = modelProvider
        self.modelsDirectory = modelsDirectory
        self.modelContext = modelContext
    }

    func service(for provider: ModelProvider) -> TranscriptionService {
        switch provider {
        case .whisper:
            return localTranscriptionService
        case .fluidAudio:
            return fluidAudioTranscriptionService
        case .nativeApple:
            return nativeAppleTranscriptionService
        default:
            return cloudTranscriptionService
        }
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let service = service(for: model.provider)
        logger.debug("Transcribing with \(model.displayName, privacy: .public) using \(String(describing: type(of: service)), privacy: .public)")
        return try await TranscriptionInferenceScheduler.shared.run(
            provider: model.provider,
            priority: .dictation
        ) {
            try await service.transcribe(audioURL: audioURL, model: model)
        }
    }

    /// Uses the language captured when a durable job was created, without changing the user's
    /// current Dictation setting underneath concurrent work.
    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        languageCode: String
    ) async throws -> String {
        let service = service(for: model.provider)
        logger.debug("Transcribing with snapshotted model \(model.displayName, privacy: .public) and language \(languageCode, privacy: .public)")
        return try await TranscriptionInferenceScheduler.shared.run(
            provider: model.provider,
            priority: .meeting
        ) {
            try await LanguagePreference.$operationOverrideCode.withValue(languageCode) {
                try await service.transcribe(audioURL: audioURL, model: model)
            }
        }
    }

    /// Creates a streaming or file-based session depending on the model's capabilities.
    func createSession(for model: any TranscriptionModel, onPartialTranscript: ((String) -> Void)? = nil) -> TranscriptionSession {
        if supportsStreaming(model: model) {
            let streamingService = StreamingTranscriptionService(
                modelContext: modelContext,
                fluidAudioService: model.provider == .fluidAudio ? fluidAudioTranscriptionService : nil,
                onPartialTranscript: onPartialTranscript
            )
            let fallback = service(for: model.provider)
            return StreamingTranscriptionSession(
                streamingService: streamingService,
                fallbackService: fallback,
                provider: model.provider
            )
        } else {
            return FileTranscriptionSession(
                service: service(for: model.provider),
                provider: model.provider
            )
        }
    }

    /// Whether the given model supports streaming transcription
    private func supportsStreaming(model: any TranscriptionModel) -> Bool {
        guard model.supportsStreaming else { return false }
        return UserDefaults.standard.object(forKey: "streaming-enabled-\(model.name)") as? Bool ?? true
    }

    func cleanup() async {
        await fluidAudioTranscriptionService.cleanup()
    }
}
