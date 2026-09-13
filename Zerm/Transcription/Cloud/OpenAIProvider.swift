import Foundation

/// OpenAI speech-to-text (`/v1/audio/transcriptions`).
///
/// `gpt-transcribe` replaced the gpt-4o transcription models, which OpenAI deprecated on
/// 2026-08-26. It takes `languages[]` instead of `language` (sending both is rejected) and biases
/// recognition with `keywords[]`; the Output Format goes in `prompt` as context.
/// https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create
struct OpenAIProvider: CloudProvider {
    let modelProvider: ModelProvider = .openai
    let providerKey: String = "OpenAI"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false
    let documentationURL = URL(string: "https://developers.openai.com/api/docs/guides/speech-to-text")!

    static let transcribeModelName = "gpt-transcribe"
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    var models: [CloudModel] {[
        CloudModel(
            name: Self.transcribeModelName,
            displayName: "GPT Transcribe (OpenAI)",
            description: String(localized: "OpenAI's current speech-to-text model with prompt and keyword support"),
            provider: .openai,
            speed: 0.8,
            accuracy: 0.97,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .openai),
            capabilities: [.prompt, .vocabulary, .languageHint],
            isRecommended: true
        )
    ]}

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> String {
        let (data, _) = try await CloudHTTP.send(Self.makeURLRequest(request), timeout: request.timeout)
        struct Response: Decodable { let text: String }
        return try CloudHTTP.decode(Response.self, from: data).text
    }

    static func makeURLRequest(_ request: CloudTranscriptionRequest) -> URLRequest {
        var form = MultipartForm()
        form.addField("model", request.model)
        form.addField("response_format", "json")
        if let language = request.language {
            form.addField("languages[]", language)
        }
        if let prompt = request.prompt {
            form.addField("prompt", prompt)
        }
        // Any `<`, `>` or line break in a keyword makes OpenAI reject the whole request.
        for keyword in CloudVocabulary.terms(request.vocabulary, limit: 100, disallowed: ["<", ">"]) {
            form.addField("keywords[]", keyword)
        }
        form.addFile("file", fileName: request.fileName, mimeType: request.audioMimeType, data: request.audioData)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.data
        return urlRequest
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(key, url: URL(string: "https://api.openai.com/v1/models")!) {
            ["Authorization": "Bearer \($0)"]
        }
    }
}
