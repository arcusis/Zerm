import Foundation

/// A text-to-speech engine. The synthesis counterpart of `CloudProvider`.
///
/// Implementations return raw 16-bit signed little-endian PCM so the shared
/// `TTSPlayer` can play any provider through one pipeline.
protocol TTSProvider {
    var kind: TTSProviderKind { get }
    var displayName: String { get }
    var voices: [TTSVoice] { get }

    /// Whether an API key is required before synthesis can run (false for local engines).
    var requiresAPIKey: Bool { get }

    /// Synthesize `text` with `voice`. `apiKey` is empty for local engines.
    /// `speed` is a 0.5–2.0 rate multiplier (providers clamp/ignore as needed).
    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?)
}

extension TTSProvider {
    var requiresAPIKey: Bool { kind.apiKeyProvider != nil }

    var apiKeyProviderID: String? { kind.apiKeyProvider }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        guard let first = voices.first else { return (false, "No voices available") }
        do {
            let audio = try await synthesize(text: "Test.", voice: first, speed: 1.0, apiKey: key)
            return audio.pcm.isEmpty ? (false, "No audio returned") : (true, nil)
        } catch let TTSError.http(code, msg) {
            return (false, "HTTP \(code): \(msg)")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

/// Central registry of available synthesis engines.
enum TTSProviderRegistry {
    static let allProviders: [any TTSProvider] = [
        KokoroTTSProvider(),
        DeepgramTTSProvider(),
        InworldTTSProvider(),
        ElevenLabsTTSProvider(),
        GeminiTTSProvider(),
        OpenAITTSProvider(),
        CartesiaTTSProvider()
    ]

    static func provider(for kind: TTSProviderKind) -> (any TTSProvider)? {
        allProviders.first { $0.kind == kind }
    }
}

// MARK: - Shared HTTP helpers

enum TTSHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// POST `body` to `request` and return the raw response bytes, throwing `TTSError.http` on non-2xx.
    static func post(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TTSError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown"
            throw TTSError.http(http.statusCode, message)
        }
        guard !data.isEmpty else { throw TTSError.emptyAudio }
        return data
    }
}
