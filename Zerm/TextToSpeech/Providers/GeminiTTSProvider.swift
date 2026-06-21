import Foundation

/// Google Gemini 3.1 Flash TTS — prompt-steerable speech via the `generateContent` API.
///
/// Unlike most providers, Gemini returns a JSON envelope rather than raw audio: the PCM
/// is base64-encoded at `candidates[0].content.parts[0].inlineData.data`, decoded here to
/// 24kHz / 16-bit / mono signed little-endian PCM.
/// Docs: POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
struct GeminiTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .gemini
    let displayName = "Gemini 3.1 Flash TTS"

    private let model = "gemini-3.1-flash-tts"

    let voices: [TTSVoice] = [
        TTSVoice(id: "Kore", displayName: "Kore (firm)", provider: .gemini),
        TTSVoice(id: "Puck", displayName: "Puck (upbeat)", provider: .gemini),
        TTSVoice(id: "Charon", displayName: "Charon (informative)", provider: .gemini),
        TTSVoice(id: "Aoede", displayName: "Aoede (breezy)", provider: .gemini),
        TTSVoice(id: "Fenrir", displayName: "Fenrir (excitable)", provider: .gemini),
        TTSVoice(id: "Leda", displayName: "Leda (youthful)", provider: .gemini),
        TTSVoice(id: "Orus", displayName: "Orus (firm)", provider: .gemini),
        TTSVoice(id: "Zephyr", displayName: "Zephyr (bright)", provider: .gemini),
        TTSVoice(id: "Callirrhoe", displayName: "Callirrhoe (easy-going)", provider: .gemini),
        TTSVoice(id: "Enceladus", displayName: "Enceladus (breathy)", provider: .gemini)
    ]

    // MARK: - Request / response shapes

    private struct Request: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig

        struct Content: Encodable {
            let parts: [Part]
        }
        struct Part: Encodable {
            let text: String
        }
        struct GenerationConfig: Encodable {
            let responseModalities: [String]
            let speechConfig: SpeechConfig
        }
        struct SpeechConfig: Encodable {
            let voiceConfig: VoiceConfig
        }
        struct VoiceConfig: Encodable {
            let prebuiltVoiceConfig: PrebuiltVoiceConfig
        }
        struct PrebuiltVoiceConfig: Encodable {
            let voiceName: String
        }
    }

    private struct Response: Decodable {
        let candidates: [Candidate]?

        struct Candidate: Decodable {
            let content: Content?
        }
        struct Content: Decodable {
            let parts: [Part]?
        }
        struct Part: Decodable {
            let inlineData: InlineData?

            enum CodingKeys: String, CodingKey {
                case inlineData
            }
        }
        struct InlineData: Decodable {
            let data: String?
        }
    }

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        guard !apiKey.isEmpty else { throw TTSError.missingAPIKey(displayName) }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

        let payload = Request(
            contents: [.init(parts: [.init(text: text)])],
            generationConfig: .init(
                responseModalities: ["AUDIO"],
                speechConfig: .init(
                    voiceConfig: .init(
                        prebuiltVoiceConfig: .init(voiceName: voice.id)
                    )
                )
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await TTSHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TTSError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown"
            throw TTSError.http(http.statusCode, message)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let base64 = decoded.candidates?.first?.content?.parts?.first?.inlineData?.data else {
            throw TTSError.badResponse
        }
        guard let pcm = Data(base64Encoded: base64) else { throw TTSError.badResponse }
        guard !pcm.isEmpty else { throw TTSError.emptyAudio }

        return TTSAudio(pcm: pcm, sampleRate: 24000, channels: 1)
    }
}
