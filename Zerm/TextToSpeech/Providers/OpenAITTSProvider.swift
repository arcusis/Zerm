import Foundation

/// OpenAI `gpt-4o-mini-tts` — steerable speech with natural, expressive voices.
///
/// Requests raw `pcm` so the shared `TTSPlayer` gets headerless 24kHz / 16-bit /
/// mono signed little-endian samples with no container parsing.
/// Docs: POST https://api.openai.com/v1/audio/speech  (Authorization: Bearer).
struct OpenAITTSProvider: TTSProvider {
    let kind: TTSProviderKind = .openai
    let displayName = "OpenAI gpt-4o-mini-tts"

    let voices: [TTSVoice] = [
        TTSVoice(id: "alloy", displayName: "Alloy (neutral, balanced)", provider: .openai),
        TTSVoice(id: "ash", displayName: "Ash (warm, expressive)", provider: .openai),
        TTSVoice(id: "ballad", displayName: "Ballad (smooth, lyrical)", provider: .openai),
        TTSVoice(id: "coral", displayName: "Coral (bright, friendly)", provider: .openai),
        TTSVoice(id: "echo", displayName: "Echo (calm, measured)", provider: .openai),
        TTSVoice(id: "fable", displayName: "Fable (animated, storytelling)", provider: .openai),
        TTSVoice(id: "nova", displayName: "Nova (energetic, upbeat)", provider: .openai),
        TTSVoice(id: "onyx", displayName: "Onyx (deep, authoritative)", provider: .openai),
        TTSVoice(id: "sage", displayName: "Sage (gentle, grounded)", provider: .openai),
        TTSVoice(id: "shimmer", displayName: "Shimmer (soft, soothing)", provider: .openai),
        TTSVoice(id: "verse", displayName: "Verse (versatile, natural)", provider: .openai),
        TTSVoice(id: "marin", displayName: "Marin (clear, confident)", provider: .openai),
        TTSVoice(id: "cedar", displayName: "Cedar (rich, steady)", provider: .openai)
    ]

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        guard !apiKey.isEmpty else { throw TTSError.missingAPIKey(displayName) }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // gpt-4o-mini-tts accepts speed 0.25–4.0; clamp the app's 0.5–2.0 range to be safe.
        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": text,
            "voice": voice.id,
            "response_format": "pcm",
            "speed": min(max(speed, 0.25), 4.0)
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let pcm = try await TTSHTTP.post(request)
        return TTSAudio(pcm: pcm, sampleRate: 24000, channels: 1)
    }
}
