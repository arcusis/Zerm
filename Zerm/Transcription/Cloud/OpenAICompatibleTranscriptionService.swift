import Foundation

/// Why a custom OpenAI-compatible endpoint failed, phrased for the person who configured it.
enum CustomEndpointError: LocalizedError, Equatable {
    case invalidURL
    case unauthorized
    case notFound
    case unsupportedMediaType
    case rejected(String)
    case rateLimited
    case serverError(Int)
    case unexpectedResponse
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "The endpoint URL is not valid.")
        case .unauthorized:
            return String(localized: "The endpoint rejected the API key (HTTP 401/403). Check the key and that it has access to transcription.")
        case .notFound:
            return String(localized: "Nothing answered at this URL (HTTP 404/405). Zerm posts audio directly to it, so use the full transcription endpoint, usually ending in /v1/audio/transcriptions.")
        case .unsupportedMediaType:
            return String(localized: "The endpoint does not accept multipart audio uploads (HTTP 415). It may not be OpenAI-compatible.")
        case .rejected(let message):
            return String(localized: "The endpoint rejected the request. Check the model name and language. Details: \(message)")
        case .rateLimited:
            return String(localized: "The endpoint is rate limiting requests (HTTP 429). Try again shortly.")
        case .serverError(let statusCode):
            return String(localized: "The endpoint had a server error (HTTP \(statusCode)). Try again later.")
        case .unexpectedResponse:
            return String(localized: "The endpoint answered, but not with a transcription. Expected JSON with a \"text\" field or plain text.")
        case .unreachable(let message):
            return String(localized: "Could not reach the endpoint: \(message)")
        }
    }

    /// Maps a transport or HTTP failure to what the user should fix.
    static func from(_ error: Error) -> Error {
        switch error {
        case CloudTranscriptionError.apiRequestFailed(let statusCode, let message):
            switch statusCode {
            case 401, 403: return CustomEndpointError.unauthorized
            case 404, 405: return CustomEndpointError.notFound
            case 415: return CustomEndpointError.unsupportedMediaType
            case 429: return CustomEndpointError.rateLimited
            case 500...: return CustomEndpointError.serverError(statusCode)
            default: return CustomEndpointError.rejected(String(message.prefix(300)))
            }
        case CloudTranscriptionError.noTranscriptionReturned:
            return CustomEndpointError.unexpectedResponse
        case CloudTranscriptionError.networkError(let underlying):
            return CustomEndpointError.unreachable(underlying.localizedDescription)
        default:
            return error
        }
    }
}

/// Transcription through any endpoint that implements OpenAI's `/v1/audio/transcriptions`.
class OpenAICompatibleTranscriptionService {
    func transcribe(_ request: CloudTranscriptionRequest, model: CustomCloudModel) async throws -> String {
        guard let endpoint = Self.endpointURL(model.apiEndpoint) else {
            throw CustomEndpointError.invalidURL
        }
        do {
            let urlRequest = Self.makeURLRequest(endpoint: endpoint, request: request)
            let (data, response) = try await CloudHTTP.send(urlRequest, timeout: request.timeout)
            return try Self.transcript(from: data, response: response)
        } catch {
            throw CustomEndpointError.from(error)
        }
    }

    /// Sends a one-second generated tone the way a real dictation would be sent. An endpoint that
    /// answers with a parseable transcription (even an empty one) is verified.
    func verify(endpoint: String, apiKey: String, modelName: String, isMultilingual: Bool, language: String?) async throws {
        guard let url = Self.endpointURL(endpoint) else {
            throw CustomEndpointError.invalidURL
        }
        let request = CloudTranscriptionRequest(
            audioData: Self.verificationAudio(),
            fileName: "zerm-verify.wav",
            apiKey: apiKey,
            model: modelName,
            language: isMultilingual ? language : nil,
            timeout: 30
        )
        do {
            let (data, response) = try await CloudHTTP.send(Self.makeURLRequest(endpoint: url, request: request), timeout: request.timeout, maxRetries: 0)
            _ = try Self.transcript(from: data, response: response, allowEmpty: true)
        } catch {
            throw CustomEndpointError.from(error)
        }
    }

    static func endpointURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else {
            return nil
        }
        return url
    }

    /// Whisper-style multipart request. Vocabulary rides in `prompt` because the OpenAI-compatible
    /// shape has no portable keyword field; `language` is sent only when the caller passes one.
    static func makeURLRequest(endpoint: URL, request: CloudTranscriptionRequest) -> URLRequest {
        var form = MultipartForm()
        form.addField("model", request.model)
        form.addField("response_format", "json")
        form.addField("temperature", "0")
        if let language = request.language {
            form.addField("language", language)
        }
        if let prompt = CloudVocabulary.whisperPrompt(outputFormat: request.prompt, vocabulary: request.vocabulary) {
            form.addField("prompt", prompt)
        }
        form.addFile("file", fileName: request.fileName, mimeType: request.audioMimeType, data: request.audioData)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = form.data
        return urlRequest
    }

    /// Reads `json` and `verbose_json` (`{"text": …}`) or `text` responses, whichever the server
    /// returns regardless of the requested format.
    static func transcript(from data: Data, response: HTTPURLResponse, allowEmpty: Bool = false) throws -> String {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard let body = String(data: data, encoding: .utf8) else {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        if contentType.contains("json") || trimmed.hasPrefix("{") {
            struct Response: Decodable { let text: String }
            return try CloudHTTP.decode(Response.self, from: data).text
        }
        if contentType.contains("html") || trimmed.hasPrefix("<") || (trimmed.isEmpty && !allowEmpty) {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
        return trimmed
    }

    /// One second of a quiet 440 Hz tone as 16 kHz mono 16-bit WAV. Some servers reject pure
    /// digital silence as "no audio".
    static func verificationAudio() -> Data {
        let sampleRate = 16_000
        let samples = (0..<sampleRate).map { index -> Int16 in
            Int16(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * 1_000)
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(Data("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))              // fmt chunk size
        append(UInt16(1))               // PCM
        append(UInt16(1))               // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))  // byte rate
        append(UInt16(2))               // block align
        append(UInt16(16))              // bits per sample
        data.append(Data("data".utf8))
        append(UInt32(byteCount))
        samples.forEach { append($0) }
        return data
    }
}
