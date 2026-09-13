import Foundation

// Enum to differentiate between model providers
enum ModelProvider: String, Codable, Hashable, CaseIterable {
    case whisper = "Whisper"
    case fluidAudio = "Parakeet"
    case groq = "Groq"
    case elevenLabs = "ElevenLabs"
    case deepgram = "Deepgram"
    case mistral = "Mistral"
    case gemini = "Gemini"
    case soniox = "Soniox"
    case speechmatics = "Speechmatics"
    case xai = "xAI"
    case openai = "OpenAI"
    case assemblyAI = "AssemblyAI"
    case gladia = "Gladia"
    case custom = "Custom"
    case nativeApple = "Native Apple"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // "Local" was the raw value before renaming to "Whisper"
        if raw == "Local" {
            self = .whisper
            return
        }
        guard let value = ModelProvider(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ModelProvider: \(raw)")
        }
        self = value
    }
}

/// Transcription-time features a model actually honours. Settings are shown only when the
/// selected model declares the matching capability, so every visible control has an effect.
struct TranscriptionCapabilities: OptionSet, Hashable {
    let rawValue: Int

    /// Accepts the per-language Output Format text as a style prompt or context.
    static let prompt = TranscriptionCapabilities(rawValue: 1 << 0)
    /// Biases recognition toward Dictionary terms (keyterms, context terms, prompt suffix).
    static let vocabulary = TranscriptionCapabilities(rawValue: 1 << 1)
    /// Accepts the selected language as a hint or constraint.
    static let languageHint = TranscriptionCapabilities(rawValue: 1 << 2)
    /// Can transcribe live while recording.
    static let streaming = TranscriptionCapabilities(rawValue: 1 << 3)
    /// Can label speakers (used for file transcription, not dictation).
    static let diarization = TranscriptionCapabilities(rawValue: 1 << 4)
}

// A unified protocol for any transcription model
protocol TranscriptionModel: Identifiable, Hashable {
    var id: UUID { get }
    var name: String { get }
    var displayName: String { get }
    var description: String { get }
    var provider: ModelProvider { get }
    
    // Language capabilities
    var isMultilingualModel: Bool { get }
    var supportedLanguages: [String: String] { get }

    var supportsStreaming: Bool { get }

    var capabilities: TranscriptionCapabilities { get }
    var languageGroup: ModelLanguageGroup { get }
    /// Listed under "Great in Hebrew".
    var isHebrewOptimized: Bool { get }
    /// Cloud models only; local recommendations are derived from this Mac's hardware.
    var isRecommended: Bool { get }
}

enum ModelLanguageGroup {
    case englishOnly
    case multilingual
}

extension TranscriptionModel {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var language: String {
        isMultilingualModel ? "Multilingual" : "English-only"
    }

    var supportsStreaming: Bool { false }

    var languageGroup: ModelLanguageGroup {
        isMultilingualModel ? .multilingual : .englishOnly
    }

    var capabilities: TranscriptionCapabilities {
        var capabilities: TranscriptionCapabilities = supportsStreaming ? [.streaming] : []
        switch provider {
        case .whisper:
            // whisper.cpp takes the Output Format plus Dictionary terms as its initial prompt.
            capabilities.formUnion([.prompt, .vocabulary])
            if isMultilingualModel { capabilities.insert(.languageHint) }
        case .nativeApple:
            capabilities.insert(.languageHint)
        default:
            break
        }
        return capabilities
    }

    var isHebrewOptimized: Bool { false }
    var isRecommended: Bool { false }
}

// A new struct for Apple's native models
struct NativeAppleModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .nativeApple
    let isMultilingualModel: Bool
    let languageGroup: ModelLanguageGroup = .multilingual
    private let catalogLanguages: [String: String]

    /// Hebrew is added only once `SpeechTranscriber` has reported it at runtime.
    var supportedLanguages: [String: String] {
        guard AppleSpeechLanguageSupport.supportsHebrew else { return catalogLanguages }
        return catalogLanguages.merging(["he": "Hebrew"]) { current, _ in current }
    }

    init(name: String, displayName: String, description: String, isMultilingualModel: Bool, supportedLanguages: [String: String]) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.isMultilingualModel = isMultilingualModel
        self.catalogLanguages = supportedLanguages
    }
}

// A new struct for FluidAudio models
struct FluidAudioModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .fluidAudio
    let size: String
    let speed: Double
    let accuracy: Double
    let ramUsage: Double
    let supportsStreaming: Bool
    var isMultilingualModel: Bool {
        supportedLanguages.count > 1
    }
    let supportedLanguages: [String: String]

    init(name: String, displayName: String, description: String, size: String, speed: Double, accuracy: Double, ramUsage: Double, supportsStreaming: Bool = false, supportedLanguages: [String: String]) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.size = size
        self.speed = speed
        self.accuracy = accuracy
        self.ramUsage = ramUsage
        self.supportsStreaming = supportsStreaming
        self.supportedLanguages = supportedLanguages
    }
}

// A new struct for cloud models
struct CloudModel: TranscriptionModel {
    let id: UUID
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider
    let speed: Double
    let accuracy: Double
    let isMultilingualModel: Bool
    let supportsStreaming: Bool
    let supportedLanguages: [String: String]
    let capabilities: TranscriptionCapabilities
    /// Strong on Hebrew and on Hebrew/English mixed speech.
    let isHebrewOptimized: Bool
    /// The best current model of its provider.
    let isRecommended: Bool

    init(id: UUID = UUID(), name: String, displayName: String, description: String, provider: ModelProvider, speed: Double, accuracy: Double, isMultilingual: Bool, supportsStreaming: Bool = false, supportedLanguages: [String: String], capabilities: TranscriptionCapabilities = [], isHebrewOptimized: Bool = false, isRecommended: Bool = false) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.provider = provider
        self.speed = speed
        self.accuracy = accuracy
        self.isMultilingualModel = isMultilingual
        self.supportsStreaming = supportsStreaming
        self.supportedLanguages = supportedLanguages
        self.capabilities = supportsStreaming ? capabilities.union(.streaming) : capabilities
        self.isHebrewOptimized = isHebrewOptimized
        self.isRecommended = isRecommended
    }
}

/// Custom cloud model with API key stored in Keychain.
struct CustomCloudModel: TranscriptionModel, Codable {
    /// Result of the last live test call against the endpoint.
    enum VerificationStatus: String, Codable {
        /// Saved before verification existed; kept usable until a verification fails.
        case legacy
        case unverified
        case verified
        case failed
    }

    let id: UUID
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .custom
    let apiEndpoint: String
    let modelName: String
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]
    var verificationStatus: VerificationStatus
    var lastVerifiedAt: Date?

    /// API key retrieved from Keychain by model ID.
    var apiKey: String {
        APIKeyManager.shared.getCustomModelAPIKey(forModelId: id) ?? ""
    }

    /// OpenAI-compatible endpoints take `prompt` (Output Format plus Dictionary terms) and, for
    /// multilingual models, `language`.
    var capabilities: TranscriptionCapabilities {
        isMultilingualModel ? [.prompt, .vocabulary, .languageHint] : [.prompt, .vocabulary]
    }

    /// Only endpoints that answered a real transcription request can be selected.
    var isUsable: Bool {
        verificationStatus == .verified || verificationStatus == .legacy
    }

    init(id: UUID = UUID(), name: String, displayName: String, description: String, apiEndpoint: String, modelName: String, isMultilingual: Bool = true, supportedLanguages: [String: String]? = nil, verificationStatus: VerificationStatus = .unverified, lastVerifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.apiEndpoint = apiEndpoint
        self.modelName = modelName
        self.isMultilingualModel = isMultilingual
        self.supportedLanguages = supportedLanguages ?? LanguageDictionary.forProvider(isMultilingual: isMultilingual)
        self.verificationStatus = verificationStatus
        self.lastVerifiedAt = lastVerifiedAt
    }

    /// Custom Codable to migrate legacy apiKey from JSON to Keychain.
    private enum CodingKeys: String, CodingKey {
        case id, name, displayName, description, apiEndpoint, modelName, isMultilingualModel, supportedLanguages
        case verificationStatus, lastVerifiedAt
        case apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decode(String.self, forKey: .description)
        apiEndpoint = try container.decode(String.self, forKey: .apiEndpoint)
        modelName = try container.decode(String.self, forKey: .modelName)
        isMultilingualModel = try container.decode(Bool.self, forKey: .isMultilingualModel)
        supportedLanguages = try container.decode([String: String].self, forKey: .supportedLanguages)
        verificationStatus = try container.decodeIfPresent(VerificationStatus.self, forKey: .verificationStatus) ?? .legacy
        lastVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)

        if let legacyApiKey = try container.decodeIfPresent(String.self, forKey: .apiKey), !legacyApiKey.isEmpty {
            APIKeyManager.shared.saveCustomModelAPIKey(legacyApiKey, forModelId: id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(description, forKey: .description)
        try container.encode(apiEndpoint, forKey: .apiEndpoint)
        try container.encode(modelName, forKey: .modelName)
        try container.encode(isMultilingualModel, forKey: .isMultilingualModel)
        try container.encode(supportedLanguages, forKey: .supportedLanguages)
        try container.encode(verificationStatus, forKey: .verificationStatus)
        try container.encodeIfPresent(lastVerifiedAt, forKey: .lastVerifiedAt)
    }
}

struct WhisperModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let size: String
    let supportedLanguages: [String: String]
    let description: String
    let speed: Double
    let accuracy: Double
    let ramUsage: Double
    let provider: ModelProvider = .whisper
    let isHebrewOptimized: Bool
    /// The pinned Hugging Face file this model is downloaded from.
    let source: ModelIntegrity.PinnedFile

    init(name: String, displayName: String, size: String, supportedLanguages: [String: String], description: String, speed: Double, accuracy: Double, ramUsage: Double, isHebrewOptimized: Bool = false, source: ModelIntegrity.PinnedFile? = nil) {
        self.name = name
        self.displayName = displayName
        self.size = size
        self.supportedLanguages = supportedLanguages
        self.description = description
        self.speed = speed
        self.accuracy = accuracy
        self.ramUsage = ramUsage
        self.isHebrewOptimized = isHebrewOptimized
        self.source = source ?? .whisperCpp(fileName: "\(name).bin")
    }

    var downloadURL: String {
        source.downloadURL
    }

    /// Local file name inside the WhisperModels directory.
    var filename: String {
        "\(name).bin"
    }

    var isMultilingualModel: Bool {
        supportedLanguages.count > 1
    }

    /// Hebrew fine-tunes detect the spoken language poorly, so Auto (or a language they were
    /// not tuned for) runs as Hebrew. An explicit English choice is kept.
    func transcriptionLanguageCode(forSelected code: String) -> String {
        guard isHebrewOptimized else { return code }
        return code == "en" ? "en" : "he"
    }
}

// User-imported local models 
struct ImportedWhisperModel: TranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .whisper
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]

    init(fileBaseName: String) {
        self.name = fileBaseName
        self.displayName = fileBaseName
        self.description = "Imported local model"
        self.isMultilingualModel = true
        self.supportedLanguages = LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper)
    }
}