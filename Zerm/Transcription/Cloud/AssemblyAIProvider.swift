import Foundation
import SwiftData

/// AssemblyAI transcription provider.
///
/// AssemblyAI uses an async upload → submit → poll flow rather than the OpenAI
/// `/v1/audio/transcriptions` shape, so this provider does its own URLSession
/// networking (mirroring the app-side OpenAICompatibleTranscriptionService) instead
/// of delegating to an LLMkit client. Auth is the raw key in the `authorization`
/// header — AssemblyAI does not use a `Bearer` prefix.
struct AssemblyAIProvider: CloudProvider {
    let modelProvider: ModelProvider = .assemblyAI
    let providerKey: String = "AssemblyAI"
    let languageCodes: [String]? = nil
    let includesAutoDetect: Bool = false

    private static let base = "https://api.assemblyai.com"

    var models: [CloudModel] {[
        CloudModel(
            name: "universal-3-5-pro",
            displayName: "Universal 3.5 Pro (AssemblyAI)",
            description: "AssemblyAI's flagship model with native code-switching and high accuracy",
            provider: .assemblyAI,
            speed: 0.8,
            accuracy: 0.97,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .assemblyAI)
        ),
        CloudModel(
            name: "universal-2",
            displayName: "Universal 2 (AssemblyAI)",
            description: "AssemblyAI's previous-generation model with broad language coverage",
            provider: .assemblyAI,
            speed: 0.85,
            accuracy: 0.95,
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .assemblyAI)
        )
    ]}

    func transcribe(audioData: Data, fileName: String, apiKey: String, model: String, language: String?, prompt: String?, customVocabulary: [String]) async throws -> String {
        let uploadURL = try await upload(audioData: audioData, apiKey: apiKey)
        let id = try await submit(audioURL: uploadURL, model: model, language: language, apiKey: apiKey)
        return try await poll(id: id, apiKey: apiKey)
    }

    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, "API key is missing or empty.") }

        var request = URLRequest(url: URL(string: "\(Self.base)/v2/transcript?limit=1")!)
        request.timeoutInterval = 10
        request.setValue(trimmed, forHTTPHeaderField: "authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (false, "No HTTP response received.") }
            if (200..<300).contains(http.statusCode) { return (true, nil) }
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            return (false, message)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Upload → submit → poll

    private func upload(audioData: Data, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.base)/v2/upload")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await CloudUploadSession.upload(request, body: audioData)
        try Self.validate(response, data: data)

        struct UploadResponse: Decodable { let upload_url: String }
        guard let url = try? JSONDecoder().decode(UploadResponse.self, from: data).upload_url else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        return url
    }

    private func submit(audioURL: String, model: String, language: String?, apiKey: String) async throws -> String {
        var body: [String: Any] = [
            "audio_url": audioURL,
            // Renamed from the deprecated singular `speech_model`; the array is the
            // current field and takes ids like universal-3-5-pro / universal-2.
            "speech_models": [model]
        ]
        if let language, !language.isEmpty, language != "auto" {
            body["language_code"] = language
        } else {
            body["language_detection"] = true
        }

        var request = URLRequest(url: URL(string: "\(Self.base)/v2/transcript")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)

        struct SubmitResponse: Decodable { let id: String }
        guard let id = try? JSONDecoder().decode(SubmitResponse.self, from: data).id else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        return id
    }

    private func poll(id: String, apiKey: String, maxWaitSeconds: TimeInterval = 300) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.base)/v2/transcript/\(id)")!)
        request.setValue(apiKey, forHTTPHeaderField: "authorization")

        struct PollResponse: Decodable { let status: String; let text: String?; let error: String? }

        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response, data: data)
            let decoded = try JSONDecoder().decode(PollResponse.self, from: data)
            switch decoded.status {
            case "completed":
                return decoded.text ?? ""
            case "error":
                throw CloudTranscriptionError.apiRequestFailed(statusCode: 200, message: decoded.error ?? "AssemblyAI transcription failed")
            default:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw CloudTranscriptionError.noTranscriptionReturned
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error message"
            throw CloudTranscriptionError.apiRequestFailed(statusCode: http.statusCode, message: message)
        }
    }
}
