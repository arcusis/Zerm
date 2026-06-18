import Foundation

/// Cartesia Sonic-3.5 — low-latency cloud TTS.
///
/// Uses the simple HTTP bytes endpoint (not the WebSocket) and requests raw
/// signed 16-bit little-endian PCM at 24 kHz so it drops straight into the
/// shared `TTSPlayer` pipeline.
/// Docs: POST https://api.cartesia.ai/tts/bytes  (X-API-Key + Cartesia-Version).
struct CartesiaTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .cartesia
    let displayName = "Cartesia Sonic-3.5"

    /// Pinned API version date. Cartesia requires this header on every request.
    private let apiVersion = "2025-04-16"
    private let modelID = "sonic-3.5"

    let voices: [TTSVoice] = [
        TTSVoice(id: "f786b574-daa5-4673-aa0c-cbe3e8534c02", displayName: "Katie (US, female)", provider: .cartesia),
        TTSVoice(id: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", displayName: "Skylar (US, female)", provider: .cartesia),
        TTSVoice(id: "a5136bf9-224c-4d76-b823-52bd5efcffcc", displayName: "Jameson (US, male)", provider: .cartesia),
        TTSVoice(id: "62ae83ad-4f6a-430b-af41-a9bede9286ca", displayName: "Gemma (UK, female)", provider: .cartesia, language: "en"),
        TTSVoice(id: "ef191366-f52f-447a-a398-ed8c0f2943a1", displayName: "Archie (UK, male)", provider: .cartesia, language: "en")
    ]

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        guard !apiKey.isEmpty else { throw TTSError.missingAPIKey(displayName) }

        let body: [String: Any] = [
            "model_id": modelID,
            "transcript": text,
            "voice": [
                "mode": "id",
                "id": voice.id
            ],
            "output_format": [
                "container": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": 24000
            ],
            "language": voice.language
        ]

        var request = URLRequest(url: URL(string: "https://api.cartesia.ai/tts/bytes")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(apiVersion, forHTTPHeaderField: "Cartesia-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let pcm = try await TTSHTTP.post(request)
        return TTSAudio(pcm: pcm, sampleRate: 24000, channels: 1)
    }
}
