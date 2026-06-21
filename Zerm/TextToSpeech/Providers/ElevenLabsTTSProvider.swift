import Foundation

/// ElevenLabs v3 — the most expressive cloud Read Aloud provider.
///
/// Uses the default premade voice library so it works the moment a user pastes an
/// API key (no voice cloning or library setup required).
/// Docs: POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}
/// Header `xi-api-key`, `output_format=pcm_24000` yields headerless 24kHz/16-bit/mono signed LE PCM.
struct ElevenLabsTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .elevenLabs
    let displayName = "ElevenLabs v3"

    /// The expressive premium model. `eleven_flash_v2_5` is available for low-latency use.
    private let modelID = "eleven_v3"

    let voices: [TTSVoice] = [
        TTSVoice(id: "21m00Tcm4TlvDq8ikWAM", displayName: "Rachel (calm, narration)", provider: .elevenLabs, isPremium: true),
        TTSVoice(id: "EXAVITQu4vr4xnSDxMaL", displayName: "Bella (soft, young)", provider: .elevenLabs, isPremium: true),
        TTSVoice(id: "AZnzlk1XvdvUeBnXmlld", displayName: "Domi (strong, confident)", provider: .elevenLabs, isPremium: true),
        TTSVoice(id: "XB0fDUnXU5powFXDhCwa", displayName: "Charlotte (warm, expressive)", provider: .elevenLabs, isPremium: true),
        TTSVoice(id: "pNInz6obpgDQGcFmaJgB", displayName: "Adam (deep, narration)", provider: .elevenLabs, isPremium: true),
        TTSVoice(id: "ErXwobaYiN019PkySvjV", displayName: "Antoni (well-rounded)", provider: .elevenLabs, isPremium: true),
        TTSVoice(id: "TxGEqnHWrfWFTfGW9XjX", displayName: "Josh (deep, young)", provider: .elevenLabs, isPremium: true),
        TTSVoice(id: "VR6AewLTigWG4xSOukaG", displayName: "Arnold (crisp, firm)", provider: .elevenLabs, isPremium: true)
    ]

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        guard !apiKey.isEmpty else { throw TTSError.missingAPIKey(displayName) }

        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice.id)")!
        components.queryItems = [
            URLQueryItem(name: "output_format", value: "pcm_24000")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": modelID
        ])

        let pcm = try await TTSHTTP.post(request)
        return TTSAudio(pcm: pcm, sampleRate: 24000, channels: 1)
    }
}
