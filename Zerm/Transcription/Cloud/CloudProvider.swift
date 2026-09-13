import Foundation
import SwiftData

protocol CloudProvider {
    var modelProvider: ModelProvider { get }
    var providerKey: String { get }
    var languageCodes: [String]? { get }
    var includesAutoDetect: Bool { get }
    var models: [CloudModel] { get }
    /// Official speech-to-text documentation, shown with the provider's models.
    var documentationURL: URL { get }
    /// Capabilities the live streaming path applies. Streaming clients take language and
    /// vocabulary at most, so settings that only the batch request honours are hidden while
    /// real-time mode is on.
    var streamingCapabilities: TranscriptionCapabilities { get }

    func transcribe(_ request: CloudTranscriptionRequest) async throws -> String
    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)?
    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?)
}

extension CloudProvider {
    var streamingCapabilities: TranscriptionCapabilities { [] }
    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)? { nil }

    /// Verifies a key with a cheap authenticated GET.
    func verifyAPIKey(_ key: String, url: URL, headers: (String) -> [String: String]) async -> (isValid: Bool, errorMessage: String?) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, String(localized: "API key is missing or empty.")) }

        var request = URLRequest(url: url)
        headers(trimmed).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        do {
            _ = try await CloudHTTP.send(request, timeout: 15, maxRetries: 0)
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

enum CloudProviderRegistry {
    static let allProviders: [any CloudProvider] = [
        OpenAIProvider(),
        GeminiProvider(),
        ElevenLabsProvider(),
        SonioxProvider(),
        AssemblyAIProvider(),
        DeepgramProvider(),
        GroqProvider(),
        MistralProvider(),
        SpeechmaticsProvider(),
        GladiaProvider(),
        XAIProvider()
    ]

    static func provider(for modelProvider: ModelProvider) -> (any CloudProvider)? {
        allProviders.first { $0.modelProvider == modelProvider }
    }
}
