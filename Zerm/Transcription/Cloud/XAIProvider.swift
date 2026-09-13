import Foundation
import SwiftData

/// xAI speech-to-text (`/v1/stt`). The endpoint takes no model id and no prompt; Dictionary
/// terms go in repeated `keyterm` fields. Options must precede the file part. Hebrew is not
/// among its 25 languages.
/// https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
struct XAIProvider: CloudProvider {
    let modelProvider: ModelProvider = .xai
    let providerKey: String = "xAI"
    let languageCodes: [String]? = [
        "ar", "cs", "da", "nl", "en", "fil", "fr", "de", "hi", "id",
        "it", "ja", "ko", "mk", "ms", "fa", "pl", "pt", "ro", "ru",
        "es", "sv", "th", "tr", "vi"
    ]
    let includesAutoDetect: Bool = true
    let documentationURL = URL(string: "https://docs.x.ai/developers/model-capabilities/audio/speech-to-text")!
    let streamingCapabilities: TranscriptionCapabilities = [.languageHint]

    private static let endpoint = URL(string: "https://api.x.ai/v1/stt")!

    var models: [CloudModel] {[
        CloudModel(
            name: "grok-stt",
            displayName: "Grok (xAI)",
            description: String(localized: "xAI's Grok speech-to-text with real-time streaming and batch transcription. Does not support Hebrew."),
            provider: .xai,
            speed: 0.99,
            accuracy: 0.98,
            isMultilingual: true,
            supportsStreaming: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .xai),
            capabilities: [.vocabulary, .languageHint, .diarization],
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
        if let language = request.language {
            form.addField("language", language)
            // Number and currency formatting requires an explicit language.
            form.addField("format", "true")
        }
        for term in CloudVocabulary.terms(request.vocabulary, limit: 100, maxCharacters: 50) {
            form.addField("keyterm", term)
        }
        form.addFile("file", fileName: request.fileName, mimeType: request.audioMimeType, data: request.audioData)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.data
        return urlRequest
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        XAIStreamingProvider()
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(key, url: URL(string: "https://api.x.ai/v1/api-key")!) {
            ["Authorization": "Bearer \($0)"]
        }
    }
}
