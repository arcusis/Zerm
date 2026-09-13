import Foundation
import SwiftData
import LLMkit

/// Speechmatics batch transcription through LLMkit (enhanced model). Dictionary terms go in
/// `additional_vocab`; Speechmatics has no prompt field.
/// https://docs.speechmatics.com/speech-to-text/batch/input
struct SpeechmaticsProvider: CloudProvider {
    let modelProvider: ModelProvider = .speechmatics
    let providerKey: String = "Speechmatics"
    let languageCodes: [String]? = [
        "ar", "ba", "eu", "be", "bn", "bg", "yue", "ca", "hr", "cs", "da",
        "nl", "en", "et", "fi", "fr", "gl", "de", "el", "he", "hi",
        "hu", "id", "it", "ja", "ko", "lv", "lt", "ms", "mt", "mr",
        "mn", "no", "fa", "pl", "pt", "ro", "ru", "sk", "sl", "es",
        "sw", "sv", "tl", "ta", "th", "tr", "uk", "ur", "vi", "cy",
        "zh"
    ]
    let includesAutoDetect: Bool = true
    let documentationURL = URL(string: "https://docs.speechmatics.com/speech-to-text/models")!
    let streamingCapabilities: TranscriptionCapabilities = [.vocabulary, .languageHint]

    var models: [CloudModel] {[
        CloudModel(
            name: "speechmatics-enhanced",
            displayName: "Speechmatics",
            description: String(localized: "Speechmatics enhanced accuracy transcription with real-time streaming and 50+ language support"),
            provider: .speechmatics,
            speed: 0.99,
            accuracy: 0.98,
            isMultilingual: true,
            supportsStreaming: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .speechmatics),
            capabilities: [.vocabulary, .languageHint, .diarization],
            isRecommended: true
        )
    ]}

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> String {
        try await SpeechmaticsClient.transcribe(
            audioData: request.audioData,
            fileName: request.fileName,
            apiKey: request.apiKey,
            language: request.language,
            operatingPoint: "enhanced",
            customVocabulary: request.vocabulary,
            maxWaitSeconds: request.timeout,
            timeout: request.timeout
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        SpeechmaticsStreamingProvider(modelContext: modelContext)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await SpeechmaticsClient.verifyAPIKey(key)
    }
}
