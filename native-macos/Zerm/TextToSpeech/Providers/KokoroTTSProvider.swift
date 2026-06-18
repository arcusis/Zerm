import Foundation

/// Local, on-device neural TTS via sherpa-onnx + Kokoro-82M (Apache-2.0 weights).
///
/// Fully offline: no API key, no network after the one-time model download (handled by
/// `KokoroModelManager`, mirroring `WhisperModelManager`). `voice.id` is the sherpa-onnx
/// speaker id (sid) for the `kokoro-en-v0_19` package.
struct KokoroTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .kokoro
    let displayName = "Kokoro (on-device)"

    // sid order for kokoro-en-v0_19 (0:af, 1:af_bella, 2:af_nicole, 3:af_sarah, 4:af_sky,
    // 5:am_adam, 6:am_michael, 7:bf_emma, 8:bf_isabella, 9:bm_george, 10:bm_lewis).
    let voices: [TTSVoice] = [
        TTSVoice(id: "1", displayName: "Bella (American, female)", provider: .kokoro),
        TTSVoice(id: "3", displayName: "Sarah (American, female)", provider: .kokoro),
        TTSVoice(id: "4", displayName: "Sky (American, female)", provider: .kokoro),
        TTSVoice(id: "5", displayName: "Adam (American, male)", provider: .kokoro),
        TTSVoice(id: "6", displayName: "Michael (American, male)", provider: .kokoro),
        TTSVoice(id: "7", displayName: "Emma (British, female)", provider: .kokoro),
        TTSVoice(id: "8", displayName: "Isabella (British, female)", provider: .kokoro),
        TTSVoice(id: "9", displayName: "George (British, male)", provider: .kokoro),
        TTSVoice(id: "10", displayName: "Lewis (British, male)", provider: .kokoro)
    ]

    var requiresAPIKey: Bool { false }

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        let sid = Int(voice.id) ?? 0
        return try await KokoroModelManager.shared.synthesize(text: text, sid: sid, speed: speed)
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        (true, nil)
    }
}
