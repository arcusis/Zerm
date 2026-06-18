import Foundation

/// Local, on-device neural TTS via sherpa-onnx + Kokoro-82M (Apache-2.0).
///
/// SCAFFOLD: the native sherpa-onnx library + Kokoro model manager land in issue #210
/// (requires adding the sherpa-onnx binary dependency to the Xcode project — the one piece
/// that can't be a pure-Swift drop-in). The provider is registered now so the rest of the
/// Read Aloud subsystem compiles and ships with cloud providers; synthesis throws until the
/// engine is wired up.
struct KokoroTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .kokoro
    let displayName = "Kokoro (on-device)"

    let voices: [TTSVoice] = [
        TTSVoice(id: "af_heart", displayName: "Heart (American, warm)", provider: .kokoro),
        TTSVoice(id: "af_bella", displayName: "Bella (American)", provider: .kokoro),
        TTSVoice(id: "am_michael", displayName: "Michael (American)", provider: .kokoro),
        TTSVoice(id: "bf_emma", displayName: "Emma (British)", provider: .kokoro),
        TTSVoice(id: "bm_george", displayName: "George (British)", provider: .kokoro)
    ]

    var requiresAPIKey: Bool { false }

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        throw TTSError.notAvailable("On-device Kokoro voices are coming soon (issue #210). Pick a cloud provider in Read Aloud settings for now.")
    }

    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?) {
        (true, nil)
    }
}
