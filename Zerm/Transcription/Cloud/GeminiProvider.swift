import Foundation
import LLMkit

/// Gemini's dedicated transcription model through LLMkit. Language goes in `language_codes` and
/// Dictionary terms in `custom_vocabulary`; the model has no prompt field.
/// https://ai.google.dev/gemini-api/docs/transcribe
struct GeminiProvider: CloudProvider {
    let modelProvider: ModelProvider = .gemini
    let providerKey: String = "Gemini"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false
    let documentationURL = URL(string: "https://ai.google.dev/gemini-api/docs/transcribe")!

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
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .gemini),
            capabilities: [.vocabulary, .languageHint, .diarization],
            isHebrewOptimized: true,
            isRecommended: true
        )
    ]}

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> String {
        try await GeminiTranscriptionClient.transcribe(
            audioData: request.audioData,
            apiKey: request.apiKey,
            model: request.model,
            mimeType: request.audioMimeType,
            fileName: request.fileName,
            language: request.language,
            customVocabulary: request.vocabulary,
            timeout: request.timeout
        )
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await GeminiTranscriptionClient.verifyAPIKey(key)
    }
}
