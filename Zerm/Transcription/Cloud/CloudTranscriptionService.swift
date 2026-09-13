import Foundation
import AVFoundation
import SwiftData
import LLMkit

enum CloudTranscriptionError: Error, LocalizedError {
    case unsupportedProvider
    case missingAPIKey
    case invalidAPIKey
    case audioFileNotFound
    case apiRequestFailed(statusCode: Int, message: String)
    case networkError(Error)
    case noTranscriptionReturned
    case dataEncodingError
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return String(localized: "The model provider is not supported by this service.")
        case .missingAPIKey:
            return String(localized: "API key for this service is missing. Please configure it in the settings.")
        case .invalidAPIKey:
            return String(localized: "The provided API key is invalid.")
        case .audioFileNotFound:
            return String(localized: "The audio file to transcribe could not be found.")
        case .apiRequestFailed(let statusCode, let message):
            return String(localized: "The API request failed with status code \(statusCode): \(message)")
        case .networkError(let error):
            return String(localized: "A network error occurred: \(error.localizedDescription)")
        case .noTranscriptionReturned:
            return String(localized: "The API returned an empty or invalid response.")
        case .dataEncodingError:
            return String(localized: "Failed to encode the request body.")
        case .timedOut(let seconds):
            return String(localized: "The transcription service did not answer within \(seconds) seconds. You can raise the cloud timeout in Model Settings.")
        }
    }
}

class CloudTranscriptionService: TranscriptionService {
    private let modelContext: ModelContext
    private lazy var openAICompatibleService = OpenAICompatibleTranscriptionService()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let audioData = try loadAudioData(from: audioURL)
        let vocabulary = VocabularyTerms.transcriptionTerms(from: modelContext)
        let timeout = CloudTranscriptionSettings.timeout(forAudioDuration: Self.audioDuration(of: audioURL, byteCount: audioData.count))

        do {
            let text: String
            if model.provider == .custom {
                guard let customModel = model as? CustomCloudModel else {
                    throw CloudTranscriptionError.unsupportedProvider
                }
                let request = Self.makeRequest(
                    for: customModel,
                    audioData: audioData,
                    fileName: audioURL.lastPathComponent,
                    apiKey: customModel.apiKey,
                    vocabulary: vocabulary,
                    timeout: timeout
                )
                text = try await openAICompatibleService.transcribe(request, model: customModel)
            } else {
                guard let cloudProvider = CloudProviderRegistry.provider(for: model.provider) else {
                    throw CloudTranscriptionError.unsupportedProvider
                }
                let request = Self.makeRequest(
                    for: model,
                    audioData: audioData,
                    fileName: audioURL.lastPathComponent,
                    apiKey: try requireAPIKey(forProvider: cloudProvider.providerKey),
                    vocabulary: vocabulary,
                    timeout: timeout
                )
                text = try await cloudProvider.transcribe(request)
            }
            // Empty body from cloud STT is a provider failure, not silence —
            // treating it as success surfaces as "Nothing transcribed".
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CloudTranscriptionError.noTranscriptionReturned
            }
            return text
        } catch let error as CloudTranscriptionError {
            throw error
        } catch let error as CustomEndpointError {
            throw error
        } catch let error as LLMKitError {
            throw mapLLMKitError(error, timeout: timeout)
        } catch {
            throw CloudTranscriptionError.networkError(error)
        }
    }

    /// Builds the provider request, passing only what the model declares it honours: the
    /// Output Format for the request's own language, Dictionary terms, and the language hint.
    static func makeRequest(
        for model: any TranscriptionModel,
        audioData: Data,
        fileName: String,
        apiKey: String,
        vocabulary: [String],
        timeout: TimeInterval,
        defaults: UserDefaults = .standard
    ) -> CloudTranscriptionRequest {
        let capabilities = model.capabilities
        let language = LanguagePreference.apiLanguage(defaults: defaults)
        return CloudTranscriptionRequest(
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: model.name,
            language: capabilities.contains(.languageHint) ? language : nil,
            prompt: capabilities.contains(.prompt) ? WhisperPrompt.resolvedPrompt(for: language ?? LanguagePreference.autoCode, defaults: defaults) : nil,
            vocabulary: capabilities.contains(.vocabulary) ? vocabulary : [],
            timeout: timeout
        )
    }

    // MARK: - Helpers

    private func loadAudioData(from url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CloudTranscriptionError.audioFileNotFound
        }
        return try Data(contentsOf: url)
    }

    /// Audio length in seconds; falls back to the size of 16 kHz mono 16-bit PCM.
    private static func audioDuration(of url: URL, byteCount: Int) -> TimeInterval {
        if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            return Double(file.length) / file.fileFormat.sampleRate
        }
        return Double(byteCount) / 32_000
    }

    private func requireAPIKey(forProvider provider: String) throws -> String {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: provider), !apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }
        return apiKey
    }

    private func mapLLMKitError(_ error: LLMKitError, timeout: TimeInterval) -> CloudTranscriptionError {
        switch error {
        case .missingAPIKey:
            return .missingAPIKey
        case .httpError(let statusCode, let message):
            return .apiRequestFailed(statusCode: statusCode, message: message)
        case .noResultReturned:
            return .noTranscriptionReturned
        case .encodingError:
            return .dataEncodingError
        case .unsupportedModel:
            return .unsupportedProvider
        case .timeout:
            return .timedOut(seconds: Int(timeout))
        case .networkError(let detail):
            return .networkError(NSError(domain: "LLMkit", code: -1, userInfo: [NSLocalizedDescriptionKey: detail]))
        case .invalidURL, .decodingError:
            return .networkError(error)
        }
    }
}
