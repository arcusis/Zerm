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
    private(set) lazy var parakeetUnifiedTranscriptionService = ParakeetUnifiedTranscriptionService()

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

    /// Routes models that share a provider but not an engine, and pins the language of Hebrew fine-tunes.
    func service(for model: any TranscriptionModel) -> TranscriptionService {
        if model.name == FluidAudioModelManager.unifiedModelName {
            return parakeetUnifiedTranscriptionService
        }
        if let whisperModel = model as? WhisperModel, whisperModel.isHebrewOptimized {
            return HebrewFineTuneTranscriptionService(base: localTranscriptionService, model: whisperModel)
        }
        return service(for: model.provider)
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let service = service(for: model)
        logger.debug("Transcribing with \(model.displayName, privacy: .public) using \(String(describing: type(of: service)), privacy: .public)")
        return try await TranscriptionInferenceScheduler.shared.run(
            provider: model.provider,
            priority: .dictation
        ) {
            try await service.transcribe(audioURL: audioURL, model: model)
        }
    }

    /// Background transcription with the language captured when the job was created, without
    /// changing the user's current Dictation setting underneath concurrent work.
    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        languageCode: String
    ) async throws -> String {
        let service = service(for: model)
        logger.debug("Transcribing with snapshotted model \(model.displayName, privacy: .public) and language \(languageCode, privacy: .public)")
        return try await TranscriptionInferenceScheduler.shared.run(
            provider: model.provider,
            priority: .background
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
            let fallback = service(for: model)
            return StreamingTranscriptionSession(
                streamingService: streamingService,
                fallbackService: fallback,
                provider: model.provider
            )
        } else {
            return FileTranscriptionSession(
                service: service(for: model),
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
        // Parakeet Unified stays loaded between dictations, like Whisper: its manager keeps no
        // per-recording state, and reloading the encoder each time would add latency.
        await fluidAudioTranscriptionService.cleanup()
    }
}

/// ivrit.ai models detect the spoken language poorly: run them with the language they were tuned
/// for (see `WhisperModel.transcriptionLanguageCode(forSelected:)`) through the operation override
/// the Whisper service already honors.
struct HebrewFineTuneTranscriptionService: TranscriptionService {
    let base: TranscriptionService
    let model: WhisperModel

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let languageCode = self.model.transcriptionLanguageCode(forSelected: LanguagePreference.selectedCode())
        return try await LanguagePreference.$operationOverrideCode.withValue(languageCode) {
            try await base.transcribe(audioURL: audioURL, model: model)
        }
    }
}
