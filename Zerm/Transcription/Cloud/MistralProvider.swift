import Foundation
import SwiftData

/// Mistral Voxtral Mini Transcribe 2 (`/v1/audio/transcriptions`). Dictionary terms go in
/// repeated `context_bias` fields; there is no prompt field. Voxtral supports 13 languages and
/// not Hebrew.
/// https://docs.mistral.ai/api/endpoint/audio/transcriptions
struct MistralProvider: CloudProvider {
    let modelProvider: ModelProvider = .mistral
    let providerKey: String = "Mistral"
    let languageCodes: [String]? = ["ar", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "nl", "pt", "ru", "zh"]
    let includesAutoDetect: Bool = true
    let documentationURL = URL(string: "https://docs.mistral.ai/studio/audio/speech_to_text/offline_transcription")!

    static let transcribeModelName = "voxtral-mini-2602"
    private static let endpoint = URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!

    var models: [CloudModel] {[
        CloudModel(
            name: Self.transcribeModelName,
            displayName: "Voxtral Mini Transcribe 2 (Mistral)",
            description: String(localized: "Mistral's low-cost transcription model for 13 major languages. Does not support Hebrew."),
            provider: .mistral,
            speed: 0.99,
            accuracy: 0.96,
            isMultilingual: true,
            // Streaming disabled: the realtime model id (voxtral-mini-transcribe-realtime-2602)
            // was retired by Mistral and now 400s on every connect (#36). Use batch transcription.
            supportsStreaming: false,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .mistral),
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
        form.addField("model", request.model)
        // Mistral rejects `language` together with timestamps; Zerm never requests timestamps.
        if let language = request.language {
            form.addField("language", language)
        }
        for term in CloudVocabulary.terms(request.vocabulary, limit: 100) {
            form.addField("context_bias", term)
        }
        form.addFile("file", fileName: request.fileName, mimeType: request.audioMimeType, data: request.audioData)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.data
        return urlRequest
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        MistralStreamingProvider()
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(key, url: URL(string: "https://api.mistral.ai/v1/models")!) {
            ["Authorization": "Bearer \($0)"]
        }
    }
}
