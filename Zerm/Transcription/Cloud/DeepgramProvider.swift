import Foundation
import SwiftData

/// Deepgram pre-recorded transcription (`/v1/listen`). Dictionary terms go in repeated `keyterm`
/// parameters; Deepgram has no free-text prompt.
/// https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded
struct DeepgramProvider: CloudProvider {
    let modelProvider: ModelProvider = .deepgram
    let providerKey: String = "Deepgram"
    let languageCodes: [String]? = Self.nova3LanguageCodes
    let includesAutoDetect: Bool = true
    let documentationURL = URL(string: "https://developers.deepgram.com/docs/models-languages-overview")!
    let streamingCapabilities: TranscriptionCapabilities = [.vocabulary, .languageHint]

    private static let endpoint = "https://api.deepgram.com/v1/listen"

    /// Languages Deepgram documents for Nova-3 (VoiceInk 3c211da, re-checked 2026-09-13).
    /// "Auto-detect" is sent as `multi`, which covers only English, Spanish, French, German,
    /// Hindi, Russian, Portuguese, Japanese, Italian and Dutch — Hebrew must be chosen explicitly.
    static let nova3LanguageCodes = [
        "af", "af-ZA",
        "ar", "ar-AE", "ar-SA", "ar-QA", "ar-KW", "ar-SY", "ar-LB", "ar-PS", "ar-JO", "ar-EG",
        "ar-SD", "ar-TD", "ar-MA", "ar-DZ", "ar-TN", "ar-IQ", "ar-IR",
        "hy", "as", "as-IN", "be", "bn", "bs", "bg", "ca",
        "zh-HK", "zh", "zh-CN", "zh-Hans", "zh-TW", "zh-Hant",
        "hr", "cs", "cs-CZ", "da", "da-DK", "nl",
        "en", "en-US", "en-AU", "en-GB", "en-IN", "en-NZ",
        "et", "fi", "nl-BE", "fr", "fr-CA", "ka", "ka-GE", "de", "de-CH", "el", "gu", "gu-IN",
        "he", "hi", "hu", "id", "it", "ja", "kn", "kk", "kk-KZ", "ko", "ko-KR",
        "lv", "lt", "mk", "ms", "mr", "mn", "ne", "no", "ps", "ps-AF", "fa", "pl",
        "pt", "pt-BR", "pt-PT", "pa", "pa-IN", "ro", "ru", "sr", "sk", "sl",
        "es", "es-419", "sv", "sv-SE", "tl", "ta", "te", "th", "th-TH", "tr", "tr-TR",
        "uk", "ur", "vi"
    ]

    static let nova3MedicalLanguageCodes = ["en", "en-US", "en-AU", "en-CA", "en-GB", "en-IE", "en-IN", "en-NZ"]

    var models: [CloudModel] {[
        CloudModel(
            name: "nova-3",
            displayName: "Nova 3 (Deepgram)",
            description: String(localized: "Deepgram's fast Nova 3 model. Auto-detect covers ten major languages; choose Hebrew explicitly."),
            provider: .deepgram,
            speed: 0.99,
            accuracy: 0.96,
            isMultilingual: true,
            supportsStreaming: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .deepgram),
            capabilities: [.vocabulary, .languageHint, .diarization],
            isRecommended: true
        ),
        CloudModel(
            name: "nova-3-medical",
            displayName: "Nova 3 Medical (Deepgram)",
            description: String(localized: "Specialized English-only medical transcription model optimized for clinical environments"),
            provider: .deepgram,
            speed: 0.99,
            accuracy: 0.96,
            isMultilingual: false,
            supportsStreaming: true,
            supportedLanguages: LanguageDictionary.forCodes(Self.nova3MedicalLanguageCodes),
            capabilities: [.vocabulary, .diarization]
        )
    ]}

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> String {
        let (data, _) = try await CloudHTTP.send(Self.makeURLRequest(request), timeout: request.timeout)
        struct Response: Decodable {
            struct Results: Decodable { let channels: [Channel] }
            struct Channel: Decodable { let alternatives: [Alternative] }
            struct Alternative: Decodable { let transcript: String }
            let results: Results
        }
        let response = try CloudHTTP.decode(Response.self, from: data)
        return response.results.channels.first?.alternatives.first?.transcript ?? ""
    }

    static func makeURLRequest(_ request: CloudTranscriptionRequest) -> URLRequest {
        var components = URLComponents(string: endpoint)!
        var queryItems = [
            URLQueryItem(name: "model", value: request.model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true")
        ]
        if let language = resolvedLanguage(request.language, model: request.model) {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        // Deepgram rejects more than 500 tokens of keyterms in total.
        for term in CloudVocabulary.terms(request.vocabulary, limit: 100, maxTotalCharacters: 1_500) {
            queryItems.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = queryItems

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Token \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(request.audioMimeType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = request.audioData
        return urlRequest
    }

    /// Deepgram performs no language auto-detection when the `language` param is omitted — it
    /// silently transcribes as English. For the multilingual Nova-3 model, "multi" enables
    /// Deepgram's built-in multilingual code-switching, so "Auto detect" actually works. (VoiceInk #742)
    /// Nova-3 Medical is English-only, so a non-English app language falls back to its default.
    static func resolvedLanguage(_ language: String?, model: String) -> String? {
        if model == "nova-3-medical" {
            return language.flatMap { nova3MedicalLanguageCodes.contains($0) ? $0 : nil }
        }
        // Treat "auto" the same as nil so nova-3 becomes "multi".
        if let language, !language.isEmpty, language != "auto" { return language }
        return model == "nova-3" ? "multi" : nil
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        DeepgramStreamingProvider(modelContext: modelContext)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(key, url: URL(string: "https://api.deepgram.com/v1/projects")!) {
            ["Authorization": "Token \($0)"]
        }
    }
}
