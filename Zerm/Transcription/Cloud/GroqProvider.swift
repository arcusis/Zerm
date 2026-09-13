import Foundation

/// Groq-hosted Whisper. Whisper has no separate keyword field, so the Output Format and the
/// Dictionary terms share the 224-token `prompt`.
/// https://console.groq.com/docs/speech-to-text
struct GroqProvider: CloudProvider {
    let modelProvider: ModelProvider = .groq
    let providerKey: String = "Groq"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false
    let documentationURL = URL(string: "https://console.groq.com/docs/speech-to-text")!

    static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    var models: [CloudModel] {[
        CloudModel(
            name: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo (Groq)",
            description: String(localized: "Whisper Large v3 Turbo model with Groq's lightning-speed inference"),
            provider: .groq,
            speed: 0.65,
            accuracy: 0.95,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .groq),
            capabilities: [.prompt, .vocabulary, .languageHint],
            isRecommended: true
        ),
        CloudModel(
            name: "whisper-large-v3",
            displayName: "Whisper Large v3 (Groq)",
            description: String(localized: "Full Whisper Large v3 on Groq, slower than Turbo and slightly more accurate"),
            provider: .groq,
            speed: 0.6,
            accuracy: 0.96,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .groq),
            capabilities: [.prompt, .vocabulary, .languageHint]
        )
    ]}

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> String {
        let urlRequest = OpenAICompatibleTranscriptionService.makeURLRequest(endpoint: Self.endpoint, request: request)
        let (data, response) = try await CloudHTTP.send(urlRequest, timeout: request.timeout)
        return try OpenAICompatibleTranscriptionService.transcript(from: data, response: response)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(key, url: URL(string: "https://api.groq.com/openai/v1/models")!) {
            ["Authorization": "Bearer \($0)"]
        }
    }
}
