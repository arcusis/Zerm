import Foundation
import Testing
@testable import Zerm

/// Wire-level checks for every provider request builder: model id, language presence, and where
/// the Output Format and Dictionary terms end up. No network.
struct CloudRequestBuilderTests {

    private func request(
        model: String,
        language: String? = nil,
        prompt: String? = nil,
        vocabulary: [String] = []
    ) -> CloudTranscriptionRequest {
        CloudTranscriptionRequest(
            audioData: Data("RIFFfake".utf8),
            fileName: "recording.wav",
            apiKey: "test-key",
            model: model,
            language: language,
            prompt: prompt,
            vocabulary: vocabulary,
            timeout: 42
        )
    }

    // MARK: - OpenAI

    @Test func openAIUsesLanguagesArrayKeywordsAndPrompt() {
        let urlRequest = OpenAIProvider.makeURLRequest(request(model: "gpt-transcribe", language: "he", prompt: "שלום, מה שלומך?", vocabulary: ["Zerm", "Arcusis", "bad<term>"]))
        let fields = MultipartFields(urlRequest)

        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(fields.values("model") == ["gpt-transcribe"])
        #expect(fields.values("languages[]") == ["he"])
        #expect(fields.values("language").isEmpty)
        #expect(fields.values("prompt") == ["שלום, מה שלומך?"])
        #expect(fields.values("keywords[]") == ["Zerm", "Arcusis"])
        #expect(fields.values("response_format") == ["json"])
    }

    @Test func openAIOmitsLanguageAndPromptForAutoDetect() {
        let fields = MultipartFields(OpenAIProvider.makeURLRequest(request(model: "gpt-transcribe", language: "auto", prompt: "  ")))
        #expect(fields.values("languages[]").isEmpty)
        #expect(fields.values("prompt").isEmpty)
        #expect(fields.values("keywords[]").isEmpty)
    }

    // MARK: - Groq / OpenAI-compatible

    @Test func groqPutsOutputFormatAndVocabularyInWhisperPrompt() {
        let urlRequest = OpenAICompatibleTranscriptionService.makeURLRequest(
            endpoint: GroqProvider.endpoint,
            request: request(model: "whisper-large-v3", language: "en", prompt: "Hello there.", vocabulary: ["Zerm", "SwiftUI"])
        )
        let fields = MultipartFields(urlRequest)
        #expect(urlRequest.url == GroqProvider.endpoint)
        #expect(fields.values("model") == ["whisper-large-v3"])
        #expect(fields.values("language") == ["en"])
        #expect(fields.values("prompt") == ["Hello there. Vocabulary: Zerm, SwiftUI."])
    }

    @Test func whisperPromptStaysWithinLimit() {
        let terms = (0..<200).map { "Term\($0)" }
        let prompt = CloudVocabulary.whisperPrompt(outputFormat: "Example.", vocabulary: terms)
        #expect(prompt != nil)
        #expect((prompt?.count ?? 0) <= 300)
        #expect(prompt?.hasPrefix("Example. Vocabulary: Term0, Term1") == true)
        #expect(CloudVocabulary.whisperPrompt(outputFormat: nil, vocabulary: []) == nil)
    }

    // MARK: - Deepgram

    @Test func deepgramSendsKeytermsAndMultiForAutoDetect() throws {
        let urlRequest = DeepgramProvider.makeURLRequest(request(model: "nova-3", vocabulary: ["Zerm", "zerm", "Arcusis"]))
        let url = try #require(urlRequest.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "model" }?.value == "nova-3")
        #expect(items.first { $0.name == "language" }?.value == "multi")
        #expect(items.filter { $0.name == "keyterm" }.map(\.value) == ["Zerm", "Arcusis"])
        #expect(!items.contains { $0.name == "prompt" })
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Token test-key")
        #expect(urlRequest.httpBody == Data("RIFFfake".utf8))
    }

    @Test func deepgramPassesExplicitHebrew() throws {
        let urlRequest = DeepgramProvider.makeURLRequest(request(model: "nova-3", language: "he"))
        let url = try #require(urlRequest.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "language" }?.value == "he")
    }

    @Test func deepgramMedicalNeverSendsNonEnglishLanguage() {
        #expect(DeepgramProvider.resolvedLanguage("he", model: "nova-3-medical") == nil)
        #expect(DeepgramProvider.resolvedLanguage("en-GB", model: "nova-3-medical") == "en-GB")
        #expect(DeepgramProvider.resolvedLanguage(nil, model: "nova-3-medical") == nil)
    }

    @Test func deepgramLanguageListMatchesNova3Docs() throws {
        let codes = DeepgramProvider.nova3LanguageCodes
        #expect(Set(codes).count == codes.count)
        for code in ["he", "en", "en-US", "pt-BR", "zh-HK", "es-419", "de-CH", "tr-TR", "kk-KZ"] {
            #expect(codes.contains(code))
        }
        #expect(!codes.contains("en-CA"))
        #expect(DeepgramProvider.nova3MedicalLanguageCodes == ["en", "en-US", "en-AU", "en-CA", "en-GB", "en-IE", "en-IN", "en-NZ"])

        let nova3 = try #require(DeepgramProvider().models.first { $0.name == "nova-3" })
        #expect(nova3.supportedLanguages.count == codes.count + 1)
        #expect(nova3.supportedLanguages["auto"] != nil)
        #expect(nova3.supportedLanguages["zh-HK"] == "Chinese (Cantonese, Hong Kong)")
    }

    // MARK: - ElevenLabs

    @Test func elevenLabsSendsModelLanguageAndKeyterms() {
        let urlRequest = ElevenLabsProvider.makeURLRequest(request(model: "scribe_v2", language: "he", prompt: "ignored", vocabulary: ["Zerm", "a very long phrase with too many words", "{braces}"]))
        let fields = MultipartFields(urlRequest)
        #expect(urlRequest.value(forHTTPHeaderField: "xi-api-key") == "test-key")
        #expect(fields.values("model_id") == ["scribe_v2"])
        #expect(fields.values("language_code") == ["he"])
        #expect(fields.values("keyterms") == ["Zerm"])
        #expect(fields.values("prompt").isEmpty)
    }

    @Test func elevenLabsOmitsLanguageForAutoDetect() {
        let fields = MultipartFields(ElevenLabsProvider.makeURLRequest(request(model: "scribe_v2")))
        #expect(fields.values("language_code").isEmpty)
    }

    // MARK: - Mistral

    @Test func mistralSendsLanguageAndContextBias() {
        let urlRequest = MistralProvider.makeURLRequest(request(model: MistralProvider.transcribeModelName, language: "fr", vocabulary: ["Zerm"]))
        let fields = MultipartFields(urlRequest)
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(fields.values("model") == ["voxtral-mini-2602"])
        #expect(fields.values("language") == ["fr"])
        #expect(fields.values("context_bias") == ["Zerm"])
        #expect(fields.values("prompt").isEmpty)
    }

    @Test func mistralMetadataExcludesHebrew() throws {
        let model = try #require(MistralProvider().models.first)
        #expect(model.supportedLanguages["he"] == nil)
        #expect(!model.isHebrewOptimized)
    }

    // MARK: - xAI

    @Test func xAISendsKeytermsBeforeFileAndNoModel() {
        let urlRequest = XAIProvider.makeURLRequest(request(model: "grok-stt", language: "en", vocabulary: ["Zerm"]))
        let fields = MultipartFields(urlRequest)
        #expect(fields.values("model").isEmpty)
        #expect(fields.values("language") == ["en"])
        #expect(fields.values("format") == ["true"])
        #expect(fields.values("keyterm") == ["Zerm"])
        #expect(fields.names.last == "file")
    }

    @Test func xAIOmitsLanguageAndFormatForAutoDetect() {
        let fields = MultipartFields(XAIProvider.makeURLRequest(request(model: "grok-stt")))
        #expect(fields.values("language").isEmpty)
        #expect(fields.values("format").isEmpty)
    }

    // MARK: - Soniox

    @Test func sonioxPutsOutputFormatInContextText() throws {
        let urlRequest = try SonioxProvider.makeCreateRequest(request(model: "stt-async-v5", language: "he", prompt: "שלום.", vocabulary: ["Zerm"]), fileID: "file-1")
        let body = try jsonObject(urlRequest)
        #expect(body["model"] as? String == "stt-async-v5")
        #expect(body["file_id"] as? String == "file-1")
        #expect(body["language_hints"] as? [String] == ["he"])
        #expect(body["language_hints_strict"] == nil)
        let context = try #require(body["context"] as? [String: Any])
        #expect(context["text"] as? String == "שלום.")
        #expect(context["terms"] as? [String] == ["Zerm"])
    }

    @Test func sonioxOmitsEmptyContextAndHints() throws {
        let body = try jsonObject(try SonioxProvider.makeCreateRequest(request(model: "stt-async-v5"), fileID: "file-1"))
        #expect(body["context"] == nil)
        #expect(body["language_hints"] == nil)
    }

    // MARK: - AssemblyAI

    @Test func assemblyAIFallsBackToUniversal2AndSendsKeyterms() throws {
        let urlRequest = try AssemblyAIProvider.makeSubmitRequest(request(model: "universal-3-5-pro", language: "he", prompt: "ignored", vocabulary: ["Zerm"]), audioURL: "https://cdn/upload")
        let body = try jsonObject(urlRequest)
        #expect(urlRequest.value(forHTTPHeaderField: "authorization") == "test-key")
        #expect(body["speech_models"] as? [String] == ["universal-3-5-pro", "universal-2"])
        #expect(body["language_code"] as? String == "he")
        #expect(body["language_detection"] == nil)
        #expect(body["keyterms_prompt"] as? [String] == ["Zerm"])
        #expect(body["prompt"] == nil)
    }

    @Test func assemblyAIDetectsLanguageWhenAuto() throws {
        let body = try jsonObject(try AssemblyAIProvider.makeSubmitRequest(request(model: "universal-2"), audioURL: "https://cdn/upload"))
        #expect(body["speech_models"] as? [String] == ["universal-2"])
        #expect(body["language_detection"] as? Bool == true)
        #expect(body["language_code"] == nil)
        #expect(body["keyterms_prompt"] == nil)
    }

    // MARK: - Gladia

    @Test func gladiaForcesSelectedLanguageOrCodeSwitches() throws {
        let pinned = try jsonObject(try GladiaProvider.makeCreateRequest(request(model: "solaria-1", language: "he"), audioURL: "https://api.gladia.io/file/1"))
        #expect(pinned["model"] as? String == "solaria-1")
        let pinnedConfig = try #require(pinned["language_config"] as? [String: Any])
        #expect(pinnedConfig["languages"] as? [String] == ["he"])
        #expect(pinnedConfig["code_switching"] as? Bool == false)

        let auto = try jsonObject(try GladiaProvider.makeCreateRequest(request(model: "solaria-1"), audioURL: "https://api.gladia.io/file/1"))
        let autoConfig = try #require(auto["language_config"] as? [String: Any])
        #expect(autoConfig["languages"] as? [String] == [])
        #expect(autoConfig["code_switching"] as? Bool == true)
        #expect(auto["custom_vocabulary"] == nil)
    }
}

// MARK: - Helpers

/// Field names and text values of a multipart body, in order.
struct MultipartFields {
    let fields: [(name: String, value: String)]

    init(_ request: URLRequest) {
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let boundary = contentType.components(separatedBy: "boundary=").last ?? ""
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        fields = body.components(separatedBy: "--\(boundary)").compactMap { part in
            guard let nameRange = part.range(of: "name=\""),
                  let nameEnd = part[nameRange.upperBound...].firstIndex(of: "\""),
                  let valueStart = part.range(of: "\r\n\r\n") else {
                return nil
            }
            let name = String(part[nameRange.upperBound..<nameEnd])
            let value = String(part[valueStart.upperBound...]).replacingOccurrences(of: "\r\n", with: "", options: .anchored.union(.backwards))
            return (name, value)
        }
    }

    var names: [String] { fields.map(\.name) }

    func values(_ name: String) -> [String] {
        fields.filter { $0.name == name }.map(\.value)
    }
}

func jsonObject(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}
