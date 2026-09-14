import Foundation

/// Gladia Solaria pre-recorded transcription: upload → create job → poll.
///
/// Gladia's custom vocabulary replaces words by sound after transcription instead of biasing
/// recognition, which can rewrite correct Hebrew words, so Dictionary terms are not sent. Gladia
/// has no prompt field. Auto-detect enables per-utterance code switching for mixed speech.
/// https://docs.gladia.io/api-reference/v2/pre-recorded/init
struct GladiaProvider: CloudProvider {
    let modelProvider: ModelProvider = .gladia
    let providerKey: String = "Gladia"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = true
    let documentationURL = URL(string: "https://docs.gladia.io/chapters/pre-recorded-stt/quickstart")!

    private static let base = "https://api.gladia.io/v2"

    var models: [CloudModel] {[
        CloudModel(
            name: "solaria-1",
            displayName: "Solaria (Gladia)",
            description: String(localized: "Gladia's Solaria model for about 100 languages, including Hebrew, with automatic language switching"),
            provider: .gladia,
            speed: 0.85,
            accuracy: 0.95,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .gladia),
            capabilities: [.languageHint, .diarization],
            isRecommended: true
        )
    ]}

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> String {
        var form = MultipartForm()
        form.addFile("audio", fileName: request.fileName, mimeType: request.audioMimeType, data: request.audioData)
        var upload = Self.authorized("\(Self.base)/upload", apiKey: request.apiKey)
        upload.httpMethod = "POST"
        upload.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        upload.httpBody = form.data
        let (uploaded, _) = try await CloudHTTP.send(upload, timeout: request.timeout)
        struct Uploaded: Decodable { let audio_url: String }
        let audioURL = try CloudHTTP.decode(Uploaded.self, from: uploaded).audio_url

        let (created, _) = try await CloudHTTP.send(Self.makeCreateRequest(request, audioURL: audioURL), timeout: request.timeout)
        struct Created: Decodable { let id: String }
        let id = try CloudHTTP.decode(Created.self, from: created).id
        defer { Task { await deleteJob(id, apiKey: request.apiKey) } }

        struct Job: Decodable {
            struct Result: Decodable {
                struct Transcription: Decodable { let full_transcript: String }
                let transcription: Transcription?
            }
            let status: String
            let result: Result?
        }
        let poll = Self.authorized("\(Self.base)/pre-recorded/\(id)", apiKey: request.apiKey)
        return try await CloudHTTP.poll(timeout: request.timeout, interval: 2) {
            let (data, _) = try await CloudHTTP.send(poll, timeout: request.timeout)
            let job = try CloudHTTP.decode(Job.self, from: data)
            switch job.status {
            case "done":
                return job.result?.transcription?.full_transcript ?? ""
            case "error":
                throw CloudTranscriptionError.apiRequestFailed(statusCode: 200, message: String(localized: "Gladia transcription failed"))
            default:
                return nil
            }
        }
    }

    static func makeCreateRequest(_ request: CloudTranscriptionRequest, audioURL: String) throws -> URLRequest {
        let languageConfig: [String: Any] = request.language.map { ["languages": [$0], "code_switching": false] }
            ?? ["languages": [String](), "code_switching": true]
        let body: [String: Any] = [
            "audio_url": audioURL,
            "model": request.model,
            "language_config": languageConfig
        ]
        var urlRequest = authorized("\(base)/pre-recorded", apiKey: request.apiKey)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try CloudHTTP.jsonBody(body)
        return urlRequest
    }

    /// Removes the job and its uploaded audio from Gladia once the transcript is read.
    private func deleteJob(_ id: String, apiKey: String) async {
        var request = Self.authorized("\(Self.base)/pre-recorded/\(id)", apiKey: apiKey)
        request.httpMethod = "DELETE"
        _ = try? await CloudHTTP.send(request, timeout: 15, maxRetries: 0)
    }

    private static func authorized(_ url: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        return request
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(key, url: URL(string: "\(Self.base)/pre-recorded?limit=1")!) {
            ["x-gladia-key": $0]
        }
    }
}
