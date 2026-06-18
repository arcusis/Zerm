import Foundation

/// Deepgram Aura-2 — the default Read Aloud provider.
///
/// Reuses the Deepgram `Authorization: Token` key the app already stores for dictation,
/// so it works with zero extra onboarding for existing Deepgram users.
/// Docs: POST https://api.deepgram.com/v1/speak  (linear16 PCM, sub-200ms).
struct DeepgramTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .deepgram
    let displayName = "Deepgram Aura-2"

    let voices: [TTSVoice] = [
        TTSVoice(id: "aura-2-thalia-en", displayName: "Thalia (clear, confident)", provider: .deepgram),
        TTSVoice(id: "aura-2-andromeda-en", displayName: "Andromeda (casual, expressive)", provider: .deepgram),
        TTSVoice(id: "aura-2-helena-en", displayName: "Helena (caring, warm)", provider: .deepgram),
        TTSVoice(id: "aura-2-apollo-en", displayName: "Apollo (confident, comfortable)", provider: .deepgram),
        TTSVoice(id: "aura-2-arcas-en", displayName: "Arcas (natural, smooth)", provider: .deepgram),
        TTSVoice(id: "aura-2-aries-en", displayName: "Aries (warm, energetic)", provider: .deepgram),
        TTSVoice(id: "aura-2-orion-en", displayName: "Orion (approachable, calm)", provider: .deepgram),
        TTSVoice(id: "aura-2-luna-en", displayName: "Luna (friendly, natural)", provider: .deepgram)
    ]

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        guard !apiKey.isEmpty else { throw TTSError.missingAPIKey(displayName) }

        var components = URLComponents(string: "https://api.deepgram.com/v1/speak")!
        components.queryItems = [
            URLQueryItem(name: "model", value: voice.id),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "24000"),
            URLQueryItem(name: "container", value: "none")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let pcm = try await TTSHTTP.post(request)
        return TTSAudio(pcm: pcm, sampleRate: 24000, channels: 1)
    }
}
