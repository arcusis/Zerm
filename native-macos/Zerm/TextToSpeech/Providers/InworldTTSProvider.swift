import Foundation

/// Inworld TTS-1.5 Mini — low-latency cloud speech (~120ms median).
///
/// Inworld returns a JSON envelope (not raw bytes): the audio is base64-encoded at
/// the top-level `audioContent` field. We request `LINEAR16` at 24kHz, which Inworld
/// delivers as a complete WAV file per response, so we strip the WAV container down to
/// the raw `data` chunk to hand the shared `TTSPlayer` headerless 16-bit / mono PCM.
/// Docs: POST https://api.inworld.ai/tts/v1/voice  (Authorization: Basic <key>).
///
/// VERIFY-AGAINST-LIVE-KEY ASSUMPTIONS (Inworld docs are sparse on these):
///  1. Auth: Inworld uses `Authorization: Basic <token>`. We assume the user pastes the
///     READY-TO-USE base64 "Basic" token from the Inworld portal and send it verbatim as
///     `Authorization: Basic \(apiKey)` (no client-side base64 encoding). If a raw key is
///     stored instead, this header would need `Data(apiKey.utf8).base64EncodedString()`.
///  2. Response container: docs state LINEAR16 chunks are "complete WAV files". We assume a
///     single non-streaming response is one WAV file and parse its `data` sub-chunk. If
///     Inworld ever returns headerless PCM here, `stripWAVHeader` falls back to returning
///     the bytes unchanged.
///  3. Model id `inworld-tts-1.5-mini` and 24kHz sample rate are confirmed in 2026 docs.
struct InworldTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .inworld
    let displayName = "Inworld TTS-1.5 Mini"

    private let model = "inworld-tts-1.5-mini"
    private let sampleRate = 24000.0

    let voices: [TTSVoice] = [
        TTSVoice(id: "Ashley", displayName: "Ashley (warm, natural)", provider: .inworld),
        TTSVoice(id: "Dennis", displayName: "Dennis (smooth, calm)", provider: .inworld),
        TTSVoice(id: "Mark", displayName: "Mark (clear, confident)", provider: .inworld),
        TTSVoice(id: "Olivia", displayName: "Olivia (friendly, British)", provider: .inworld),
        TTSVoice(id: "Sarah", displayName: "Sarah (bright, expressive)", provider: .inworld),
        TTSVoice(id: "Theodore", displayName: "Theodore (rich, measured)", provider: .inworld),
        TTSVoice(id: "Elizabeth", displayName: "Elizabeth (poised, articulate)", provider: .inworld),
        TTSVoice(id: "Edward", displayName: "Edward (deep, authoritative)", provider: .inworld),
        TTSVoice(id: "Hades", displayName: "Hades (commanding, dramatic)", provider: .inworld),
        TTSVoice(id: "Pixie", displayName: "Pixie (playful, energetic)", provider: .inworld)
    ]

    // MARK: - Request / response shapes

    private struct Request: Encodable {
        let text: String
        let voiceId: String
        let modelId: String
        let audioConfig: AudioConfig

        struct AudioConfig: Encodable {
            let audioEncoding: String
            let sampleRateHertz: Int
        }
    }

    private struct Response: Decodable {
        let audioContent: String?
    }

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        guard !apiKey.isEmpty else { throw TTSError.missingAPIKey(displayName) }

        var request = URLRequest(url: URL(string: "https://api.inworld.ai/tts/v1/voice")!)
        request.httpMethod = "POST"
        request.setValue("Basic \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // `speed` is intentionally ignored: the synthesize endpoint has no documented rate field.
        let payload = Request(
            text: text,
            voiceId: voice.id,
            modelId: model,
            audioConfig: .init(audioEncoding: "LINEAR16", sampleRateHertz: Int(sampleRate))
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await TTSHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TTSError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.prefix(300).description ?? "unknown"
            throw TTSError.http(http.statusCode, message)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let base64 = decoded.audioContent,
              let audio = Data(base64Encoded: base64) else {
            throw TTSError.badResponse
        }

        let pcm = Self.stripWAVHeader(audio)
        guard !pcm.isEmpty else { throw TTSError.emptyAudio }
        return TTSAudio(pcm: pcm, sampleRate: sampleRate, channels: 1)
    }

    /// Returns the payload of a WAV file's `data` sub-chunk, or the input unchanged if it
    /// is not a recognizable RIFF/WAVE container (i.e. already headerless PCM).
    private static func stripWAVHeader(_ data: Data) -> Data {
        // "RIFF" .... "WAVE" — minimum header is 12 bytes.
        guard data.count > 12,
              data.prefix(4).elementsEqual([0x52, 0x49, 0x46, 0x46]),     // "RIFF"
              data[data.startIndex + 8 ..< data.startIndex + 12]
                .elementsEqual([0x57, 0x41, 0x56, 0x45])                  // "WAVE"
        else { return data }

        // Walk the chunk list until the "data" chunk, honoring each chunk's declared size.
        var cursor = data.startIndex + 12
        while cursor + 8 <= data.endIndex {
            let id = data[cursor ..< cursor + 4]
            let sizeBytes = data[cursor + 4 ..< cursor + 8]
            let size = sizeBytes.enumerated().reduce(0) { acc, pair in
                acc | (Int(pair.element) << (8 * pair.offset))            // little-endian uint32
            }
            let payloadStart = cursor + 8
            if id.elementsEqual([0x64, 0x61, 0x74, 0x61]) {              // "data"
                let payloadEnd = min(payloadStart + size, data.endIndex)
                return data.subdata(in: payloadStart ..< payloadEnd)
            }
            // Chunks are word-aligned: skip an extra padding byte for odd sizes.
            cursor = payloadStart + size + (size % 2)
        }
        return data
    }
}
