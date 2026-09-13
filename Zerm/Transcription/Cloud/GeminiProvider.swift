import Foundation
import SwiftData
import LLMkit

struct GeminiProvider: CloudProvider {
    let modelProvider: ModelProvider = .gemini
    let providerKey: String = "Gemini"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false

    /// The only Gemini model LLMkit's dedicated transcription client accepts.
    static let transcribeModelName = "gemini-3.5-transcribe"

    var models: [CloudModel] {[
        CloudModel(
            name: Self.transcribeModelName,
            displayName: "Gemini 3.5 Transcribe",
            description: String(localized: "Google's dedicated speech-to-text model with custom vocabulary support"),
            provider: .gemini,
            speed: 0.9,
            accuracy: 0.97,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .gemini)
        )
    ]}

    func transcribe(audioData: Data, fileName: String, apiKey: String, model: String, language: String?, prompt: String?, customVocabulary: [String]) async throws -> String {
        return try await GeminiTranscriptionClient.transcribe(
            audioData: audioData,
            apiKey: apiKey,
            model: model,
            fileName: fileName,
            language: language,
            customVocabulary: customVocabulary
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        return await GeminiTranscriptionClient.verifyAPIKey(key)
    }
}
