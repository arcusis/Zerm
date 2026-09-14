import Foundation
import SwiftData

/// ElevenLabs Scribe (`/v1/speech-to-text`). Dictionary terms go in repeated `keyterms` fields;
/// Scribe has no prompt field for batch requests.
/// https://elevenlabs.io/docs/api-reference/speech-to-text/convert
struct ElevenLabsProvider: CloudProvider {
    let modelProvider: ModelProvider = .elevenLabs
    let providerKey: String = "ElevenLabs"
    let languageCodes: [String]? = [
        "af", "am", "ar", "as", "az", "be", "bg", "bn", "bs", "ca",
        "cs", "cy", "da", "de", "el", "en", "es", "et", "eu", "fa",
        "fi", "fil", "fr", "ga", "gl", "gu", "ha", "he", "hi", "hr",
        "hu", "hy", "id", "ig", "is", "it", "ja", "jw", "ka", "kk",
        "km", "kn", "ko", "ku", "ky", "lb", "ln", "lo", "lt", "lv",
        "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl",
        "no", "or", "pa", "pl", "ps", "pt", "ro", "ru", "sd", "sk",
        "sl", "sn", "so", "sr", "sv", "sw", "ta", "tg", "te", "th",
        "tr", "uk", "ur", "uz", "vi", "wo", "xh", "yo", "yue", "zh", "zu"
    ]
    let includesAutoDetect: Bool = true
    let documentationURL = URL(string: "https://elevenlabs.io/docs/overview/capabilities/speech-to-text")!
    let streamingCapabilities: TranscriptionCapabilities = [.vocabulary, .languageHint]

    private static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    var models: [CloudModel] {[
        CloudModel(
            name: "scribe_v2",
            displayName: "Scribe V2 (ElevenLabs)",
            description: String(localized: "ElevenLabs' Scribe V2 model for the most accurate transcription"),
            provider: .elevenLabs,
            speed: 0.99,
            accuracy: 0.98,
            isMultilingual: true,
            supportsStreaming: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .elevenLabs),
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
        form.addField("model_id", request.model)
        form.addField("temperature", "0.0")
        form.addField("tag_audio_events", "false")
        form.addField("no_verbatim", "true")
        if let language = request.language {
            form.addField("language_code", language)
        }
        for keyterm in CloudVocabulary.terms(request.vocabulary, limit: 100, maxCharacters: 49, maxWords: 5, disallowed: Set("<>{}[]\\")) {
            form.addField("keyterms", keyterm)
        }
        form.addFile("file", fileName: request.fileName, mimeType: request.audioMimeType, data: request.audioData)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.data
        return urlRequest
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        ElevenLabsStreamingProvider(modelContext: modelContext)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(key, url: URL(string: "https://api.elevenlabs.io/v1/user")!) {
            ["xi-api-key": $0]
        }
    }
}
