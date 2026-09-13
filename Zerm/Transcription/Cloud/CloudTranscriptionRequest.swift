import Foundation

/// Everything a cloud provider needs for one batch transcription. `CloudTranscriptionService`
/// fills only the fields the selected model declares in its capabilities, so a provider never has
/// to decide whether a setting applies.
struct CloudTranscriptionRequest {
    let audioData: Data
    let fileName: String
    let apiKey: String
    let model: String
    /// `nil` means automatic language detection.
    let language: String?
    /// The Output Format text for `language`; `nil` when empty or unsupported.
    let prompt: String?
    /// Dictionary terms; empty when unsupported.
    let vocabulary: [String]
    let timeout: TimeInterval

    init(audioData: Data, fileName: String, apiKey: String, model: String, language: String? = nil, prompt: String? = nil, vocabulary: [String] = [], timeout: TimeInterval = CloudTranscriptionSettings.defaultTimeout) {
        self.audioData = audioData
        self.fileName = fileName
        self.apiKey = apiKey
        self.model = model
        self.language = language.flatMap { $0.isEmpty || $0 == LanguagePreference.autoCode ? nil : $0 }
        self.prompt = prompt.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.vocabulary = vocabulary
        self.timeout = timeout
    }

    /// MIME type from the file extension; recordings are WAV, imported files may not be.
    var audioMimeType: String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "audio/wav"
        }
    }
}

/// Batch cloud transcription timeout (VoiceInk 1bab779), scaled up for long audio so file
/// transcription is not cut off by a limit chosen for short dictation.
enum CloudTranscriptionSettings {
    static let timeoutKey = "CloudTranscriptionTimeout"
    static let defaultTimeout: TimeInterval = 60
    static let timeoutOptions: [Int] = [30, 60, 120, 300, 600, 1_200, 1_800]

    /// Upper bound for a single request, matching the longest provider limit Zerm relies on.
    private static let maximumTimeout: TimeInterval = 3 * 60 * 60

    static func configuredTimeout(defaults: UserDefaults = .standard) -> TimeInterval {
        let stored = defaults.integer(forKey: timeoutKey)
        return stored > 0 ? TimeInterval(stored) : defaultTimeout
    }

    /// The configured timeout, or enough time to upload and process `audioDuration` seconds of
    /// audio when that is longer (providers typically finish well under half real time).
    static func timeout(forAudioDuration audioDuration: TimeInterval, defaults: UserDefaults = .standard) -> TimeInterval {
        let scaled = 30 + audioDuration * 0.5
        return min(max(configuredTimeout(defaults: defaults), scaled), maximumTimeout)
    }
}
