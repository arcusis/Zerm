import Foundation
import SwiftData

/// Soniox async transcription: upload file → create transcription → poll → fetch transcript.
/// The Output Format goes in `context.text` and Dictionary terms in `context.terms`.
/// https://soniox.com/docs/stt/async/async-transcription
struct SonioxProvider: CloudProvider {
    let modelProvider: ModelProvider = .soniox
    let providerKey: String = "Soniox"
    let languageCodes: [String]? = [
        "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca",
        "zh", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "gl",
        "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn",
        "kk", "ko", "lv", "lt", "mk", "ms", "ml", "mr", "no", "fa",
        "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl", "es", "sw",
        "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy"
    ]
    let includesAutoDetect: Bool = true
    let documentationURL = URL(string: "https://soniox.com/docs/stt/models")!
    let streamingCapabilities: TranscriptionCapabilities = [.vocabulary, .languageHint]

    private static let base = "https://api.soniox.com/v1"

    var models: [CloudModel] {[
        CloudModel(
            name: "stt-async-v5",
            displayName: "Soniox V5",
            description: String(localized: "Soniox transcription model v5 with high accuracy and automatic switching between languages, including Hebrew and English"),
            provider: .soniox,
            speed: 0.99,
            accuracy: 0.98,
            isMultilingual: true,
            supportsStreaming: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .soniox),
            capabilities: [.prompt, .vocabulary, .languageHint, .diarization],
            isHebrewOptimized: true,
            isRecommended: true
        )
    ]}

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> String {
        let fileID = try await upload(request)
        defer { Task { await deleteFile(fileID, apiKey: request.apiKey) } }

        let (created, _) = try await CloudHTTP.send(Self.makeCreateRequest(request, fileID: fileID), timeout: request.timeout)
        struct Created: Decodable { let id: String }
        let transcriptionID = try CloudHTTP.decode(Created.self, from: created).id

        struct Status: Decodable { let status: String; let error_message: String? }
        _ = try await CloudHTTP.poll(timeout: request.timeout) { () -> Bool? in
            let (data, _) = try await CloudHTTP.send(Self.authorized("\(Self.base)/transcriptions/\(transcriptionID)", apiKey: request.apiKey), timeout: request.timeout)
            let status = try CloudHTTP.decode(Status.self, from: data)
            switch status.status {
            case "completed": return true
            case "error": throw CloudTranscriptionError.apiRequestFailed(statusCode: 200, message: status.error_message ?? String(localized: "Soniox transcription failed"))
            default: return nil
            }
        }

        let (data, _) = try await CloudHTTP.send(Self.authorized("\(Self.base)/transcriptions/\(transcriptionID)/transcript", apiKey: request.apiKey), timeout: request.timeout)
        struct Transcript: Decodable { let text: String }
        return try CloudHTTP.decode(Transcript.self, from: data).text
    }

    /// The transcription job. A selected language is a hint, not a restriction, so English words
    /// inside Hebrew speech are still transcribed as English.
    static func makeCreateRequest(_ request: CloudTranscriptionRequest, fileID: String) throws -> URLRequest {
        var body: [String: Any] = [
            "file_id": fileID,
            "model": request.model,
            "enable_language_identification": true
        ]
        if let language = request.language {
            body["language_hints"] = [language]
        }
        var context: [String: Any] = [:]
        if let prompt = request.prompt {
            context["text"] = prompt
        }
        let terms = CloudVocabulary.terms(request.vocabulary, limit: 100)
        if !terms.isEmpty {
            context["terms"] = terms
        }
        if !context.isEmpty {
            body["context"] = context
        }

        var urlRequest = authorized("\(base)/transcriptions", apiKey: request.apiKey)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try CloudHTTP.jsonBody(body)
        return urlRequest
    }

    private func upload(_ request: CloudTranscriptionRequest) async throws -> String {
        var form = MultipartForm()
        form.addFile("file", fileName: request.fileName, mimeType: request.audioMimeType, data: request.audioData)
        var urlRequest = Self.authorized("\(Self.base)/files", apiKey: request.apiKey)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.data

        let (data, _) = try await CloudHTTP.send(urlRequest, timeout: request.timeout)
        struct Uploaded: Decodable { let id: String }
        return try CloudHTTP.decode(Uploaded.self, from: data).id
    }

    /// Uploaded audio is removed once the transcript is fetched or the job failed.
    private func deleteFile(_ fileID: String, apiKey: String) async {
        var request = Self.authorized("\(Self.base)/files/\(fileID)", apiKey: apiKey)
        request.httpMethod = "DELETE"
        _ = try? await CloudHTTP.send(request, timeout: 15, maxRetries: 0)
    }

    private static func authorized(_ url: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? {
        SonioxStreamingProvider(modelContext: modelContext)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        await verifyAPIKey(key, url: URL(string: "\(Self.base)/files")!) {
            ["Authorization": "Bearer \($0)"]
        }
    }
}
