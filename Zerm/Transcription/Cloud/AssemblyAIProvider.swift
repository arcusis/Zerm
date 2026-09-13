import Foundation

/// AssemblyAI transcription provider.
///
/// AssemblyAI uses an async upload → submit → poll flow. Auth is the raw key in the
/// `authorization` header — AssemblyAI does not use a `Bearer` prefix. Dictionary terms go in
/// `keyterms_prompt`. Its `prompt` field describes the audio's domain and ignores formatting
/// examples, so the Output Format is not sent.
/// https://www.assemblyai.com/docs/api-reference/transcripts/submit
struct AssemblyAIProvider: CloudProvider {
    let modelProvider: ModelProvider = .assemblyAI
    let providerKey: String = "AssemblyAI"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false
    let documentationURL = URL(string: "https://www.assemblyai.com/docs/getting-started/models")!

    private static let base = "https://api.assemblyai.com"
    static let flagshipModelName = "universal-3-5-pro"
    static let broadCoverageModelName = "universal-2"

    var models: [CloudModel] {[
        CloudModel(
            name: Self.flagshipModelName,
            displayName: "Universal 3.5 Pro (AssemblyAI)",
            description: String(localized: "AssemblyAI's flagship model with native code-switching, including Hebrew and English"),
            provider: .assemblyAI,
            speed: 0.8,
            accuracy: 0.97,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .assemblyAI),
            capabilities: [.vocabulary, .languageHint, .diarization],
            isHebrewOptimized: true,
            isRecommended: true
        ),
        CloudModel(
            name: Self.broadCoverageModelName,
            displayName: "Universal 2 (AssemblyAI)",
            description: String(localized: "AssemblyAI's previous-generation model with broad language coverage"),
            provider: .assemblyAI,
            speed: 0.85,
            accuracy: 0.95,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .assemblyAI),
            capabilities: [.vocabulary, .languageHint, .diarization]
        )
    ]}

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> String {
        var upload = URLRequest(url: URL(string: "\(Self.base)/v2/upload")!)
        upload.httpMethod = "POST"
        upload.setValue(request.apiKey, forHTTPHeaderField: "authorization")
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.httpBody = request.audioData
        let (uploaded, _) = try await CloudHTTP.send(upload, timeout: request.timeout)
        struct UploadResponse: Decodable { let upload_url: String }
        let audioURL = try CloudHTTP.decode(UploadResponse.self, from: uploaded).upload_url

        let (submitted, _) = try await CloudHTTP.send(Self.makeSubmitRequest(request, audioURL: audioURL), timeout: request.timeout)
        struct SubmitResponse: Decodable { let id: String }
        let id = try CloudHTTP.decode(SubmitResponse.self, from: submitted).id

        var poll = URLRequest(url: URL(string: "\(Self.base)/v2/transcript/\(id)")!)
        poll.setValue(request.apiKey, forHTTPHeaderField: "authorization")
        struct PollResponse: Decodable { let status: String; let text: String?; let error: String? }
        return try await CloudHTTP.poll(timeout: request.timeout, interval: 2) {
            let (data, _) = try await CloudHTTP.send(poll, timeout: request.timeout)
            let decoded = try CloudHTTP.decode(PollResponse.self, from: data)
            switch decoded.status {
            case "completed":
                return decoded.text ?? ""
            case "error":
                throw CloudTranscriptionError.apiRequestFailed(statusCode: 200, message: decoded.error ?? "AssemblyAI transcription failed")
            default:
                return nil
            }
        }
    }

    static func makeSubmitRequest(_ request: CloudTranscriptionRequest, audioURL: String) throws -> URLRequest {
        var body: [String: Any] = [
            "audio_url": audioURL,
            // Universal 3.5 Pro covers 18 languages; AssemblyAI routes any other language to the
            // next model in the list instead of failing the request.
            "speech_models": request.model == flagshipModelName
                ? [flagshipModelName, broadCoverageModelName]
                : [request.model]
        ]
        // `language_code` and `language_detection` together are rejected.
        if let language = request.language {
            body["language_code"] = language
        } else {
            body["language_detection"] = true
        }
        // Universal 2 accepts 200 key terms and Universal 3.5 Pro 1,000, each at most six words.
        let keyterms = CloudVocabulary.terms(request.vocabulary, limit: 100, maxWords: 6)
        if !keyterms.isEmpty {
            body["keyterms_prompt"] = keyterms
        }

        var urlRequest = URLRequest(url: URL(string: "\(base)/v2/transcript")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try CloudHTTP.jsonBody(body)
        return urlRequest
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(key, url: URL(string: "\(Self.base)/v2/transcript?limit=1")!) {
            ["authorization": $0]
        }
    }
}
