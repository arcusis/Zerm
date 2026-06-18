import Foundation

/// Identifies a text-to-speech engine. Mirrors `ModelProvider` on the dictation side.
enum TTSProviderKind: String, Codable, CaseIterable, Hashable {
    case kokoro = "Kokoro"          // local, on-device (sherpa-onnx)
    case deepgram = "Deepgram"      // default cloud provider
    case inworld = "Inworld"
    case elevenLabs = "ElevenLabs"
    case gemini = "Gemini"
    case openai = "OpenAI"
    case cartesia = "Cartesia"

    /// `APIKeyManager` provider identifier, or `nil` for the local engine.
    var apiKeyProvider: String? {
        switch self {
        case .kokoro: return nil
        case .deepgram: return "deepgram"
        case .inworld: return "inworld"
        case .elevenLabs: return "elevenlabs"
        case .gemini: return "gemini"
        case .openai: return "openai"
        case .cartesia: return "cartesia"
        }
    }

    var isLocal: Bool { self == .kokoro }
}

/// A selectable voice for a given provider.
struct TTSVoice: Identifiable, Hashable, Codable {
    let id: String                 // provider-specific voice/model identifier sent in the request
    let displayName: String
    let provider: TTSProviderKind
    var language: String = "en"
    var isPremium: Bool = false
}

/// Decoded synthesis result: raw signed 16-bit little-endian PCM, mono unless stated.
struct TTSAudio {
    let pcm: Data
    let sampleRate: Double
    let channels: Int

    init(pcm: Data, sampleRate: Double = 24000, channels: Int = 1) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

enum TTSError: LocalizedError {
    case missingAPIKey(String)
    case http(Int, String)
    case emptyAudio
    case notAvailable(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): return "Add an API key for \(p) in Read Aloud settings."
        case .http(let code, let msg): return "Provider error \(code): \(msg)"
        case .emptyAudio: return "The provider returned no audio."
        case .notAvailable(let why): return why
        case .badResponse: return "Unexpected response from the speech provider."
        }
    }
}

/// User-facing Read Aloud preferences, backed by `UserDefaults`.
enum TTSSettings {
    private static let defaults = UserDefaults.standard

    enum Keys {
        static let enabled = "ttsEnabled"
        static let provider = "ttsProviderKind"
        static let speed = "ttsSpeed"
        static let restoreClipboard = "ttsRestoreClipboard"
        static func voice(for kind: TTSProviderKind) -> String { "ttsVoice_\(kind.rawValue)" }
    }

    static var isEnabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled) }
    }

    static var providerKind: TTSProviderKind {
        get { TTSProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .deepgram }
        set { defaults.set(newValue.rawValue, forKey: Keys.provider) }
    }

    /// 0.5 – 2.0, default 1.0.
    static var speed: Double {
        get { defaults.object(forKey: Keys.speed) as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: Keys.speed) }
    }

    static func voiceID(for kind: TTSProviderKind) -> String? {
        defaults.string(forKey: Keys.voice(for: kind))
    }

    static func setVoiceID(_ id: String, for kind: TTSProviderKind) {
        defaults.set(id, forKey: Keys.voice(for: kind))
    }

    /// Resolves the selected voice for a provider, falling back to its first voice.
    static func resolvedVoice(for provider: any TTSProvider) -> TTSVoice? {
        if let saved = voiceID(for: provider.kind),
           let match = provider.voices.first(where: { $0.id == saved }) {
            return match
        }
        return provider.voices.first
    }
}
