import Foundation

enum ReadAloudMode: String, Codable, CaseIterable, Identifiable {
    case exact
    case retell
    case summarize
    case explain
    case simplify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exact: return String(localized: "Read exactly")
        case .retell: return String(localized: "Retell")
        case .summarize: return String(localized: "Summarize")
        case .explain: return String(localized: "Explain")
        case .simplify: return String(localized: "Simplify")
        }
    }

    var subtitle: String {
        switch self {
        case .exact: return String(localized: "Speak the selection without AI rewriting.")
        case .retell: return String(localized: "Analyze the selection and retell it naturally without losing its meaning.")
        case .summarize: return String(localized: "Speak a shorter version containing the important points.")
        case .explain: return String(localized: "Explain the selection clearly with enough context to understand it.")
        case .simplify: return String(localized: "Rewrite difficult language in simpler terms before speaking.")
        }
    }

    var usesLocalAI: Bool { self != .exact }
}

/// Identifies a text-to-speech engine. Mirrors `ModelProvider` on the dictation side.
enum TTSProviderKind: String, Codable, CaseIterable, Hashable {
    case appleSystem = "Apple System"
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
        case .appleSystem: return nil
        case .kokoro: return nil
        case .deepgram: return "deepgram"
        case .inworld: return "inworld"
        case .elevenLabs: return "elevenlabs"
        case .gemini: return "gemini"
        case .openai: return "openai"
        case .cartesia: return "cartesia"
        }
    }

    var isLocal: Bool { self == .kokoro || self == .appleSystem }

    /// Engines whose voice catalogue cannot pronounce anything but English. Read Aloud reroutes
    /// other languages to an installed Apple system voice (see `TTSLanguageRouter`).
    var speaksEnglishOnly: Bool { self == .kokoro || self == .deepgram }
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
struct TTSAudio: Sendable {
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
        case .missingAPIKey(let provider):
            let format = String(localized: "Add an API key for %@ in Read Aloud settings.")
            return String.localizedStringWithFormat(format, provider)
        case .http(let code, let message):
            let format = String(localized: "Provider error %lld: %@")
            return String.localizedStringWithFormat(format, code, message)
        case .emptyAudio:
            return String(localized: "The provider returned no audio.")
        case .notAvailable(let why): return why
        case .badResponse:
            return String(localized: "Unexpected response from the speech provider.")
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
        static let wordsReadAloud = "ttsWordsReadAloud"
        static let sessionsReadAloud = "ttsSessionsReadAloud"
        static let smartCleanup = "ttsSmartCleanup"
        static let naturalReadingAI = "ttsNaturalReadingAI"
        static let readingMode = "ttsReadingMode"
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

    /// Instant, offline text cleanup (acronyms, URLs, code, symbols). On by default.
    static var smartCleanup: Bool {
        get { defaults.object(forKey: Keys.smartCleanup) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.smartCleanup) }
    }

    /// On-device LLM rewrite into natural spoken language. Off by default (needs the model).
    static var naturalReadingAI: Bool {
        get { readingMode.usesLocalAI }
        set { readingMode = newValue ? .retell : .exact }
    }

    /// The transformation applied before synthesis. Read exactly is the default: it is
    /// deterministic, works without a downloaded model, and never hands the selection to a
    /// language model that could follow instructions embedded in it. The AI modes are opt-in.
    static var readingMode: ReadAloudMode {
        get {
            if let raw = defaults.string(forKey: Keys.readingMode),
               let mode = ReadAloudMode(rawValue: raw) {
                return mode
            }
            if defaults.object(forKey: Keys.naturalReadingAI) != nil {
                return defaults.bool(forKey: Keys.naturalReadingAI) ? .retell : .exact
            }
            return .exact
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.readingMode)
            defaults.set(newValue.usesLocalAI, forKey: Keys.naturalReadingAI)
        }
    }

    static func voiceID(for kind: TTSProviderKind) -> String? {
        defaults.string(forKey: Keys.voice(for: kind))
    }

    static func setVoiceID(_ id: String, for kind: TTSProviderKind) {
        defaults.set(id, forKey: Keys.voice(for: kind))
    }

    // MARK: - Usage stats (shown on the Dashboard)

    static var wordsReadAloud: Int { defaults.integer(forKey: Keys.wordsReadAloud) }
    static var sessionsReadAloud: Int { defaults.integer(forKey: Keys.sessionsReadAloud) }

    /// Records one successful Read Aloud of `text`.
    ///
    /// The monotonic `UserDefaults` counters stay for compatibility; the dashboard now
    /// reads the durable per-day store instead.
    static func recordReadAloud(of text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        defaults.set(wordsReadAloud + words, forKey: Keys.wordsReadAloud)
        defaults.set(sessionsReadAloud + 1, forKey: Keys.sessionsReadAloud)

        let countedWords = WordCounter.count(in: text)
        Task { @MainActor in
            UsageStatsService.shared.recordReadAloud(words: countedWords)
        }
    }

    /// Clears the legacy counters alongside the durable store, so "clear statistics"
    /// leaves nothing behind.
    static func resetCounters() {
        defaults.removeObject(forKey: Keys.wordsReadAloud)
        defaults.removeObject(forKey: Keys.sessionsReadAloud)
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
