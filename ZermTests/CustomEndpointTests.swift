import Foundation
import Testing
@testable import Zerm

/// Custom OpenAI-compatible provider against a local `URLProtocol` mock: response formats, error
/// mapping, verification and persisted verification state.
@Suite(.serialized)
struct CustomEndpointTests {

    private let endpoint = "https://stt.example.test/v1/audio/transcriptions"

    @discardableResult
    private func withStub<T>(status: Int, contentType: String?, body: String, _ operation: () async throws -> T) async rethrows -> T {
        StubURLProtocol.response = (status, contentType, Data(body.utf8))
        let original = CloudHTTP.makeConfiguration
        CloudHTTP.makeConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            return configuration
        }
        defer { CloudHTTP.makeConfiguration = original }
        return try await operation()
    }

    private func model(isMultilingual: Bool = true) -> CustomCloudModel {
        CustomCloudModel(name: "mock", displayName: "Mock", description: "", apiEndpoint: endpoint, modelName: "whisper-large-v3", isMultilingual: isMultilingual)
    }

    private func request(language: String? = "he") -> CloudTranscriptionRequest {
        CloudTranscriptionRequest(audioData: Data("RIFF".utf8), fileName: "a.wav", apiKey: "key", model: "whisper-large-v3", language: language, prompt: "Hi.", vocabulary: ["Zerm"], timeout: 5)
    }

    // MARK: - Response formats

    @Test func readsJSONResponse() async throws {
        let text = try await withStub(status: 200, contentType: "application/json", body: #"{"text":"שלום עולם"}"#) {
            try await OpenAICompatibleTranscriptionService().transcribe(request(), model: model())
        }
        #expect(text == "שלום עולם")

        let fields = MultipartFields(StubURLProtocol.lastRequest!)
        #expect(fields.values("language") == ["he"])
        #expect(fields.values("prompt") == ["Hi. Vocabulary: Zerm."])
        #expect(fields.values("model") == ["whisper-large-v3"])
    }

    @Test func readsVerboseJSONResponse() async throws {
        let body = #"{"task":"transcribe","language":"english","duration":1.2,"text":"Hello world","segments":[{"id":0,"start":0.0,"end":1.2,"text":"Hello world"}]}"#
        let text = try await withStub(status: 200, contentType: "application/json; charset=utf-8", body: body) {
            try await OpenAICompatibleTranscriptionService().transcribe(request(), model: model())
        }
        #expect(text == "Hello world")
    }

    @Test func readsPlainTextResponse() async throws {
        let text = try await withStub(status: 200, contentType: "text/plain; charset=utf-8", body: "Hello world\n") {
            try await OpenAICompatibleTranscriptionService().transcribe(request(), model: model())
        }
        #expect(text == "Hello world")
    }

    @Test func readsJSONWithoutContentType() async throws {
        let text = try await withStub(status: 200, contentType: nil, body: #"{"text":"Hi"}"#) {
            try await OpenAICompatibleTranscriptionService().transcribe(request(), model: model())
        }
        #expect(text == "Hi")
    }

    @Test func rejectsHTMLAndMalformedJSON() async {
        await withStub(status: 200, contentType: "text/html", body: "<html>login</html>") {
            await #expect(throws: CustomEndpointError.unexpectedResponse) {
                try await OpenAICompatibleTranscriptionService().transcribe(request(), model: model())
            }
        }
        await withStub(status: 200, contentType: "application/json", body: #"{"result":"no text field"}"#) {
            await #expect(throws: CustomEndpointError.unexpectedResponse) {
                try await OpenAICompatibleTranscriptionService().transcribe(request(), model: model())
            }
        }
    }

    // MARK: - Errors

    @Test func mapsHTTPFailuresToActionableErrors() async {
        let cases: [(Int, CustomEndpointError)] = [
            (401, .unauthorized),
            (403, .unauthorized),
            (404, .notFound),
            (405, .notFound),
            (415, .unsupportedMediaType),
            (422, .rejected(#"{"error":"bad model"}"#)),
            (429, .rateLimited),
            (503, .serverError(503))
        ]
        for (status, expected) in cases {
            await withStub(status: status, contentType: "application/json", body: #"{"error":"bad model"}"#) {
                await #expect(throws: expected) {
                    try await OpenAICompatibleTranscriptionService().verify(endpoint: endpoint, apiKey: "key", modelName: "m", isMultilingual: true, language: nil)
                }
            }
        }
    }

    @Test func rejectsInvalidEndpointURL() async {
        await #expect(throws: CustomEndpointError.invalidURL) {
            try await OpenAICompatibleTranscriptionService().verify(endpoint: "api.example.com/v1", apiKey: "key", modelName: "m", isMultilingual: true, language: nil)
        }
    }

    @Test func notFoundErrorExplainsFullEndpoint() {
        #expect(CustomEndpointError.notFound.errorDescription?.contains("/v1/audio/transcriptions") == true)
    }

    // MARK: - Verification

    @Test func verificationAcceptsEmptyTranscriptAndHonoursLanguageFlag() async throws {
        try await withStub(status: 200, contentType: "application/json", body: #"{"text":""}"#) {
            try await OpenAICompatibleTranscriptionService().verify(endpoint: endpoint, apiKey: "key", modelName: "m", isMultilingual: false, language: "he")
        }
        let fields = MultipartFields(StubURLProtocol.lastRequest!)
        #expect(fields.values("language").isEmpty)
        #expect(fields.values("model") == ["m"])
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer key")
    }

    @Test func verificationAudioIsAValidWAV() {
        let audio = OpenAICompatibleTranscriptionService.verificationAudio()
        #expect(audio.count == 44 + 32_000)
        #expect(String(decoding: audio.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: audio[8..<16], as: UTF8.self) == "WAVEfmt ")
    }

    @Test func verificationStateControlsUsability() throws {
        var model = model()
        #expect(model.verificationStatus == .unverified)
        #expect(!model.isUsable)
        model.verificationStatus = .verified
        #expect(model.isUsable)
        model.verificationStatus = .failed
        #expect(!model.isUsable)

        let encoded = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(CustomCloudModel.self, from: encoded)
        #expect(decoded.verificationStatus == .failed)
    }

    @Test func modelsSavedBeforeVerificationStayUsable() throws {
        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"old","displayName":"Old","description":"","apiEndpoint":"https://x/v1/audio/transcriptions","modelName":"whisper","isMultilingualModel":true,"supportedLanguages":{"en":"English"}}"#
        let decoded = try JSONDecoder().decode(CustomCloudModel.self, from: Data(legacy.utf8))
        #expect(decoded.verificationStatus == .legacy)
        #expect(decoded.isUsable)
    }

    // MARK: - Validation and presets

    @Test func rejectsNamesOfBuiltInAndExistingModels() {
        let builtIn = CloudProviderRegistry.allProviders.flatMap(\.models) as [any TranscriptionModel]
        let existing = [model()]

        func errors(name: String, displayName: String) -> [String] {
            CustomCloudModelManager.validationErrors(name: name, displayName: displayName, apiEndpoint: endpoint, apiKey: "k", modelName: "m", existingModels: existing, builtInModels: builtIn)
        }

        #expect(errors(name: "nova-3", displayName: "Nova 3").count == 1)
        #expect(errors(name: "gpt", displayName: "GPT Transcribe (OpenAI)").count == 1)
        #expect(errors(name: "mock", displayName: "Mock").count == 1)
        #expect(errors(name: "together", displayName: "Together").isEmpty)
        #expect(CustomCloudModelManager.validationErrors(name: "x", displayName: "X", apiEndpoint: "ftp://x", apiKey: "k", modelName: "m", existingModels: [], builtInModels: []).count == 1)
    }

    @Test func presetsAreValidOpenAICompatibleEndpoints() {
        #expect(Set(CustomEndpointPreset.all.map(\.name)) == ["Together AI", "DeepInfra", "OpenRouter"])
        for preset in CustomEndpointPreset.all {
            #expect(OpenAICompatibleTranscriptionService.endpointURL(preset.endpoint) != nil)
            #expect(preset.endpoint.hasSuffix("/v1/audio/transcriptions"))
            #expect(!preset.modelNames.isEmpty)
        }
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, contentType: String?, body: Data) = (200, nil, Data())
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        // URLSession moves httpBody into a stream before it reaches a protocol.
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            captured.httpBody = data
        }
        Self.lastRequest = captured

        var headers: [String: String] = [:]
        if let contentType = Self.response.contentType {
            headers["Content-Type"] = contentType
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
