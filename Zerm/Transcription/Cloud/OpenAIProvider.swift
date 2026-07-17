import Foundation
import SwiftData
import LLMkit

struct OpenAIProvider: CloudProvider {
    let modelProvider: ModelProvider = .openai
    let providerKey: String = "OpenAI"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false

    var models: [CloudModel] {[
        CloudModel(
            name: "gpt-4o-transcribe",
            displayName: "GPT-4o Transcribe (OpenAI)",
            description: "OpenAI's flagship speech-to-text model with high accuracy across many languages",
            provider: .openai,
            speed: 0.7,
            accuracy: 0.97,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .openai)
        ),
        CloudModel(
            name: "gpt-4o-mini-transcribe",
            displayName: "GPT-4o mini Transcribe (OpenAI)",
            description: "Faster, lower-cost OpenAI speech-to-text model",
            provider: .openai,
            speed: 0.85,
            accuracy: 0.95,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .openai)
        )
    ]}

    func transcribe(audioData: Data, fileName: String, apiKey: String, model: String, language: String?, prompt: String?, customVocabulary: [String]) async throws -> String {
        return try await OpenAITranscriptionClient.transcribe(
            baseURL: URL(string: "https://api.openai.com")!,
            audioData: audioData,
            fileName: fileName,
            apiKey: apiKey,
            model: model,
            language: language,
            prompt: prompt
        )
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        return await OpenAITranscriptionClient.verifyAPIKey(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: key
        )
    }
}
