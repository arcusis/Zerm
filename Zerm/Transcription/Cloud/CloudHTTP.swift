import Foundation

/// Shared HTTP transport for app-side cloud transcription clients.
///
/// Every request runs on a fresh ephemeral session. `URLSession.shared` caches the `Alt-Svc`
/// advertisement that Cloudflare-fronted transcription APIs send, so later connections silently
/// upgrade to HTTP/3. Several VPN clients (GlobalProtect among them) forward small QUIC packets but
/// drop full-size datagrams, which blackholes a multi-megabyte audio upload until the request
/// times out. An ephemeral session carries no Alt-Svc cache, so every upload starts on TCP; the
/// cost is one extra TLS handshake, around 0.1 s.
enum CloudHTTP {
    /// Session configuration factory; tests install a `URLProtocol` stub here.
    nonisolated(unsafe) static var makeConfiguration: () -> URLSessionConfiguration = { .ephemeral }

    private static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    /// Sends `request` and returns the body of a 2xx response. Transient failures (429, 5xx,
    /// dropped connections) are retried twice with a short backoff; timeouts are not, because the
    /// timeout already bounds how long the user waits.
    static func send(_ request: URLRequest, timeout: TimeInterval, maxRetries: Int = 2) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        var attempt = 0

        while true {
            let configuration = makeConfiguration()
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
                }
                if retryableStatusCodes.contains(http.statusCode), attempt < maxRetries {
                    attempt += 1
                    try await backoff(attempt)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    let message = String(data: data, encoding: .utf8) ?? ""
                    throw CloudTranscriptionError.apiRequestFailed(statusCode: http.statusCode, message: message)
                }
                return (data, http)
            } catch let error as URLError where error.code == .timedOut {
                throw CloudTranscriptionError.timedOut(seconds: Int(timeout))
            } catch let error as URLError where error.code != .cancelled && attempt < maxRetries {
                attempt += 1
                try await backoff(attempt)
            } catch let error as URLError {
                throw CloudTranscriptionError.networkError(error)
            }
        }
    }

    /// Decodes a JSON response body, mapping failure to "empty or invalid response".
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
    }

    static func jsonBody(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CloudTranscriptionError.dataEncodingError
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Repeats `check` every `interval` seconds until it returns a value or `timeout` elapses.
    static func poll<T>(timeout: TimeInterval, interval: TimeInterval = 1, _ check: () async throws -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let result = try await check() {
                return result
            }
            guard Date().addingTimeInterval(interval) < deadline else {
                throw CloudTranscriptionError.timedOut(seconds: Int(timeout))
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private static func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
    }
}

/// A `multipart/form-data` body builder.
struct MultipartForm {
    let boundary = "Boundary-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    var data: Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    mutating func addFile(_ name: String, fileName: String, mimeType: String, data fileData: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n".utf8))
    }
}

/// Vocabulary shaping shared by providers with term limits.
enum CloudVocabulary {
    /// Trimmed, case-insensitively unique terms that satisfy a provider's limits.
    static func terms(
        _ terms: [String],
        limit: Int,
        maxCharacters: Int = .max,
        maxWords: Int = .max,
        maxTotalCharacters: Int = .max,
        disallowed: Set<Character> = []
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var totalCharacters = 0
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= maxCharacters,
                  totalCharacters + trimmed.count <= maxTotalCharacters,
                  trimmed.split(whereSeparator: \.isWhitespace).count <= maxWords,
                  !trimmed.contains(where: { disallowed.contains($0) || $0.isNewline }),
                  seen.insert(trimmed.lowercased()).inserted else {
                continue
            }
            totalCharacters += trimmed.count
            result.append(trimmed)
            if result.count == limit { break }
        }
        return result
    }

    /// Whisper-family models take vocabulary inside the initial prompt. The Output Format text
    /// comes first; terms are appended until `maxCharacters` (Whisper prompts are capped at 224
    /// tokens, and Hebrew spends roughly one token per one or two characters).
    static func whisperPrompt(outputFormat: String?, vocabulary: [String], maxCharacters: Int = 300) -> String? {
        var prompt = String((outputFormat ?? "").prefix(maxCharacters))
        let terms = self.terms(vocabulary, limit: 100)
        if !terms.isEmpty {
            var suffix = prompt.isEmpty ? "Vocabulary:" : " Vocabulary:"
            for (index, term) in terms.enumerated() {
                let piece = (index == 0 ? " " : ", ") + term
                guard prompt.count + suffix.count + piece.count + 1 <= maxCharacters else { break }
                suffix += piece
            }
            if !suffix.hasSuffix(":") {
                prompt += suffix + "."
            }
        }
        return prompt.isEmpty ? nil : prompt
    }
}
