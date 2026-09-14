import Foundation
import KeyboardShortcuts

enum AutoSendKey: String, Codable, CaseIterable {
    case none = "none"
    case enter = "enter"
    case shiftEnter = "shiftEnter"
    case commandEnter = "commandEnter"

    /// English; views look it up with `LocalizedStringKey(displayName)`.
    var displayName: String {
        switch self {
        case .none: return "None"
        case .enter: return "Return (⏎)"
        case .shiftEnter: return "Shift + Return (⇧⏎)"
        case .commandEnter: return "Command + Return (⌘⏎)"
        }
    }

    var isEnabled: Bool {
        self != .none
    }
}

/// Settings a Power Mode may override while it is active.
///
/// Every override is optional, and `nil` means "use the global setting". A Power Mode never
/// writes to global settings: its overrides are read into the per-recording
/// `DictationSessionConfiguration` when recording starts. Earlier versions filled a missing model,
/// language and provider with whatever was global when the config was created, then wrote them
/// back on every recording, so the model a dictation used depended on which app was in front.
struct PowerModeConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var emoji: String
    var appConfigs: [AppConfig]?
    var urlConfigs: [URLConfig]?
    var selectedTranscriptionModelName: String?
    var selectedLanguage: String?
    var outputMode: DictationOutputMode?
    var selectedPrompt: String?
    var selectedAIProvider: String?
    /// Only meaningful together with `selectedAIProvider`; without one the provider's own
    /// global model selection applies.
    var selectedAIModel: String?
    /// On-screen text as enhancement context.
    var contextAwareness: Bool?
    var isTextFormattingEnabled: Bool?
    var punctuationCleanupMode: PunctuationCleanupMode?
    var lowercaseTranscription: Bool?
    var autoSendKey: AutoSendKey = .none
    var isEnabled: Bool = true
    var isDefault: Bool = false
    var hotkeyShortcut: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, appConfigs, urlConfigs
        case selectedTranscriptionModelName, selectedLanguage, outputMode, selectedPrompt
        case selectedAIProvider, selectedAIModel, contextAwareness
        case textFormatting, punctuationCleanup, lowercase
        case autoSendKey, isEnabled, isDefault, hotkeyShortcut
        // Keys written by 2.8.5 and earlier.
        case isAIEnhancementEnabled, enhancementOverride, useScreenCapture
        case isTextFormattingEnabled, punctuationCleanupMode, removePunctuation, lowercaseTranscription
        case isAutoSendEnabled, selectedWhisperModel
    }

    init(id: UUID = UUID(), name: String, emoji: String, appConfigs: [AppConfig]? = nil,
         urlConfigs: [URLConfig]? = nil, selectedTranscriptionModelName: String? = nil,
         selectedLanguage: String? = nil, outputMode: DictationOutputMode? = nil,
         selectedPrompt: String? = nil, selectedAIProvider: String? = nil, selectedAIModel: String? = nil,
         contextAwareness: Bool? = nil, isTextFormattingEnabled: Bool? = nil,
         punctuationCleanupMode: PunctuationCleanupMode? = nil, lowercaseTranscription: Bool? = nil,
         autoSendKey: AutoSendKey = .none, isEnabled: Bool = true, isDefault: Bool = false,
         hotkeyShortcut: String? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.appConfigs = appConfigs
        self.urlConfigs = urlConfigs
        self.selectedTranscriptionModelName = selectedTranscriptionModelName
        self.selectedLanguage = selectedLanguage
        self.outputMode = outputMode
        self.selectedPrompt = selectedPrompt
        self.selectedAIProvider = selectedAIProvider
        self.selectedAIModel = selectedAIModel
        self.contextAwareness = contextAwareness
        self.isTextFormattingEnabled = isTextFormattingEnabled
        self.punctuationCleanupMode = punctuationCleanupMode
        self.lowercaseTranscription = lowercaseTranscription
        self.autoSendKey = autoSendKey
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.hotkeyShortcut = hotkeyShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        emoji = try container.decode(String.self, forKey: .emoji)
        appConfigs = try container.decodeIfPresent([AppConfig].self, forKey: .appConfigs)
        urlConfigs = try container.decodeIfPresent([URLConfig].self, forKey: .urlConfigs)
        selectedTranscriptionModelName = try container.decodeIfPresent(String.self, forKey: .selectedTranscriptionModelName)
            ?? container.decodeIfPresent(String.self, forKey: .selectedWhisperModel)
        selectedLanguage = try container.decodeIfPresent(String.self, forKey: .selectedLanguage)
        selectedPrompt = try container.decodeIfPresent(String.self, forKey: .selectedPrompt)
        selectedAIProvider = try container.decodeIfPresent(String.self, forKey: .selectedAIProvider)
        selectedAIModel = try container.decodeIfPresent(String.self, forKey: .selectedAIModel)

        // Legacy configs store values that were never a choice: the toggles were seeded `false`
        // and the formatting fields had no UI. Only a value that changes something survives as an
        // override. Stored configs pass through `PowerModeMigration` first, which maps a legacy
        // "always on" against the output mode that was active at the time. Here — an imported
        // 2.8.5 settings file — "always on" cannot be resolved and inherits: turning AI on for an
        // app from ambiguous data could send dictation to a cloud provider the user never chose.
        if container.contains(.outputMode) {
            outputMode = try container.decodeIfPresent(DictationOutputMode.self, forKey: .outputMode)
        } else {
            let legacyOverride = try container.decodeIfPresent(String.self, forKey: .enhancementOverride)
            outputMode = legacyOverride == "off" ? .instant : nil
        }
        if container.contains(.contextAwareness) {
            contextAwareness = try container.decodeIfPresent(Bool.self, forKey: .contextAwareness)
        } else {
            contextAwareness = try container.decodeIfPresent(Bool.self, forKey: .useScreenCapture) == true ? true : nil
        }
        if container.contains(.textFormatting) {
            isTextFormattingEnabled = try container.decodeIfPresent(Bool.self, forKey: .textFormatting)
            punctuationCleanupMode = try container.decodeIfPresent(PunctuationCleanupMode.self, forKey: .punctuationCleanup)
            lowercaseTranscription = try container.decodeIfPresent(Bool.self, forKey: .lowercase)
        } else {
            isTextFormattingEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTextFormattingEnabled) == true ? true : nil
            let legacyPunctuation = try container.decodeIfPresent(PunctuationCleanupMode.self, forKey: .punctuationCleanupMode)
                ?? (container.decodeIfPresent(Bool.self, forKey: .removePunctuation) == true ? .removeAll : .keep)
            punctuationCleanupMode = legacyPunctuation == .keep ? nil : legacyPunctuation
            lowercaseTranscription = try container.decodeIfPresent(Bool.self, forKey: .lowercaseTranscription) == true ? true : nil
        }

        if let rawValue = try container.decodeIfPresent(String.self, forKey: .autoSendKey),
           let newKey = AutoSendKey(rawValue: rawValue) {
            autoSendKey = newKey
        } else if let oldBool = try container.decodeIfPresent(Bool.self, forKey: .isAutoSendEnabled), oldBool {
            autoSendKey = .enter
        } else {
            autoSendKey = .none
        }
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        hotkeyShortcut = try container.decodeIfPresent(String.self, forKey: .hotkeyShortcut)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(emoji, forKey: .emoji)
        try container.encodeIfPresent(appConfigs, forKey: .appConfigs)
        try container.encodeIfPresent(urlConfigs, forKey: .urlConfigs)
        try container.encodeIfPresent(selectedTranscriptionModelName, forKey: .selectedTranscriptionModelName)
        try container.encodeIfPresent(selectedLanguage, forKey: .selectedLanguage)
        try container.encode(outputMode, forKey: .outputMode)
        try container.encodeIfPresent(selectedPrompt, forKey: .selectedPrompt)
        try container.encodeIfPresent(selectedAIProvider, forKey: .selectedAIProvider)
        try container.encodeIfPresent(selectedAIModel, forKey: .selectedAIModel)
        try container.encode(contextAwareness, forKey: .contextAwareness)
        try container.encode(isTextFormattingEnabled, forKey: .textFormatting)
        try container.encode(punctuationCleanupMode, forKey: .punctuationCleanup)
        try container.encode(lowercaseTranscription, forKey: .lowercase)
        try container.encode(autoSendKey, forKey: .autoSendKey)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encodeIfPresent(hotkeyShortcut, forKey: .hotkeyShortcut)
        // 2.8.5 and earlier decode these two as required; without them a downgrade would drop
        // every Power Mode and reseed the defaults.
        try container.encode(outputMode?.usesEnhancement == true, forKey: .isAIEnhancementEnabled)
        try container.encode(contextAwareness == true, forKey: .useScreenCapture)
    }

    static func == (lhs: PowerModeConfig, rhs: PowerModeConfig) -> Bool {
        lhs.id == rhs.id
    }
}

struct AppConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var bundleIdentifier: String
    var appName: String

    init(id: UUID = UUID(), bundleIdentifier: String, appName: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
    }

    static func == (lhs: AppConfig, rhs: AppConfig) -> Bool {
        lhs.id == rhs.id
    }
}

struct URLConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var url: String

    init(id: UUID = UUID(), url: String) {
        self.id = id
        self.url = url
    }

    static func == (lhs: URLConfig, rhs: URLConfig) -> Bool {
        lhs.id == rhs.id
    }
}

class PowerModeManager: ObservableObject {
    static let shared = PowerModeManager()
    @Published var configurations: [PowerModeConfig] = []
    @Published var activeConfiguration: PowerModeConfig?

    static let configKey = "powerModeConfigurationsV2"
    private let activeConfigIdKey = "activeConfigurationId"

    private init() {
        loadConfigurations()
        seedZermDefaultsIfNeeded()

        if let activeConfigIdString = UserDefaults.standard.string(forKey: activeConfigIdKey),
           let activeConfigId = UUID(uuidString: activeConfigIdString) {
            activeConfiguration = configurations.first { $0.id == activeConfigId }
        } else {
            activeConfiguration = nil
        }
    }

    private func loadConfigurations() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let configs = try? JSONDecoder().decode([PowerModeConfig].self, from: data) {
            configurations = configs
        }
    }

    private func seedZermDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let seedVersionKey = "ZermPowerModeSeedVersion"
        let seededVersion = defaults.integer(forKey: seedVersionKey)

        var didChange = false

        if configurations.isEmpty {
            // Seeds carry triggers only. Every setting inherits, so a fresh install dictates with
            // the same model, language and prompt in every app.
            configurations = [
                PowerModeConfig(
                    id: PowerModeMigration.seededGeneralID,
                    name: "General",
                    emoji: "⚡",
                    isDefault: true
                ),
                PowerModeConfig(
                    id: PowerModeMigration.seededCodeID,
                    name: "Code",
                    emoji: "⌘",
                    appConfigs: [
                        AppConfig(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor"),
                        AppConfig(bundleIdentifier: "com.microsoft.VSCode", appName: "Visual Studio Code"),
                        AppConfig(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"),
                        AppConfig(bundleIdentifier: "com.apple.Terminal", appName: "Terminal"),
                        AppConfig(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm"),
                        AppConfig(bundleIdentifier: "dev.warp.Warp-Stable", appName: "Warp")
                    ],
                    urlConfigs: [
                        URLConfig(url: "github.com")
                    ]
                ),
                PowerModeConfig(
                    id: PowerModeMigration.seededWritingID,
                    name: "Writing",
                    emoji: "✎",
                    appConfigs: [
                        AppConfig(bundleIdentifier: "com.apple.mail", appName: "Mail"),
                        AppConfig(bundleIdentifier: "com.apple.Notes", appName: "Notes"),
                        AppConfig(bundleIdentifier: "com.google.Chrome", appName: "Google Chrome"),
                        AppConfig(bundleIdentifier: "com.apple.Safari", appName: "Safari")
                    ]
                )
            ]
            didChange = true
        } else if seededVersion < 1, !configurations.contains(where: { $0.isDefault }) {
            configurations[0].isDefault = true
            didChange = true
        }

        defaults.set(1, forKey: seedVersionKey)
        defaults.set(true, forKey: "powerModeUIFlag")

        if didChange {
            saveConfigurations()
        }
    }

    func saveConfigurations() {
        if let data = try? JSONEncoder().encode(configurations) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
        NotificationCenter.default.post(name: NSNotification.Name("PowerModeConfigurationsDidChange"), object: nil)
    }

    func addConfiguration(_ config: PowerModeConfig) {
        if !configurations.contains(where: { $0.id == config.id }) {
            configurations.append(config)
            saveConfigurations()
        }
    }

    func removeConfiguration(with id: UUID) {
        KeyboardShortcuts.setShortcut(nil, for: .powerMode(id: id))
        configurations.removeAll { $0.id == id }
        saveConfigurations()
    }

    func getConfiguration(with id: UUID) -> PowerModeConfig? {
        return configurations.first { $0.id == id }
    }

    func updateConfiguration(_ config: PowerModeConfig) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            saveConfigurations()
        }
    }

    func moveConfigurations(fromOffsets: IndexSet, toOffset: Int) {
        configurations.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveConfigurations()
    }

    func getConfigurationForURL(_ url: String) -> PowerModeConfig? {
        Self.configuration(forURL: url, in: configurations)
    }

    func getConfigurationForApp(_ bundleId: String) -> PowerModeConfig? {
        Self.configuration(forApp: bundleId, in: configurations)
    }

    func getDefaultConfiguration() -> PowerModeConfig? {
        Self.defaultConfiguration(in: configurations)
    }

    static func configuration(forURL url: String, in configurations: [PowerModeConfig]) -> PowerModeConfig? {
        let cleanedURL = cleanURL(url)
        return configurations.first { config in
            config.isEnabled && (config.urlConfigs ?? []).contains { cleanedURL.contains(cleanURL($0.url)) }
        }
    }

    static func configuration(forApp bundleId: String, in configurations: [PowerModeConfig]) -> PowerModeConfig? {
        configurations.first { config in
            config.isEnabled && (config.appConfigs ?? []).contains { $0.bundleIdentifier == bundleId }
        }
    }

    static func defaultConfiguration(in configurations: [PowerModeConfig]) -> PowerModeConfig? {
        configurations.first { $0.isEnabled && $0.isDefault }
    }

    func hasDefaultConfiguration() -> Bool {
        return configurations.contains { $0.isDefault }
    }

    func setAsDefault(configId: UUID, skipSave: Bool = false) {
        for index in configurations.indices {
            configurations[index].isDefault = false
        }

        if let index = configurations.firstIndex(where: { $0.id == configId }) {
            configurations[index].isDefault = true
        }

        if !skipSave {
            saveConfigurations()
        }
    }

    func enableConfiguration(with id: UUID) {
        if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].isEnabled = true
            saveConfigurations()
        }
    }

    func disableConfiguration(with id: UUID) {
        if let index = configurations.firstIndex(where: { $0.id == id }) {
            configurations[index].isEnabled = false
            saveConfigurations()
        }
    }

    var enabledConfigurations: [PowerModeConfig] {
        return configurations.filter { $0.isEnabled }
    }

    func addAppConfig(_ appConfig: AppConfig, to config: PowerModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            var configs = updatedConfig.appConfigs ?? []
            configs.append(appConfig)
            updatedConfig.appConfigs = configs
            updateConfiguration(updatedConfig)
        }
    }

    func removeAppConfig(_ appConfig: AppConfig, from config: PowerModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            updatedConfig.appConfigs?.removeAll(where: { $0.id == appConfig.id })
            updateConfiguration(updatedConfig)
        }
    }

    func addURLConfig(_ urlConfig: URLConfig, to config: PowerModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            var configs = updatedConfig.urlConfigs ?? []
            configs.append(urlConfig)
            updatedConfig.urlConfigs = configs
            updateConfiguration(updatedConfig)
        }
    }

    func removeURLConfig(_ urlConfig: URLConfig, from config: PowerModeConfig) {
        if var updatedConfig = configurations.first(where: { $0.id == config.id }) {
            updatedConfig.urlConfigs?.removeAll(where: { $0.id == urlConfig.id })
            updateConfiguration(updatedConfig)
        }
    }

    func cleanURL(_ url: String) -> String {
        Self.cleanURL(url)
    }

    static func cleanURL(_ url: String) -> String {
        return url.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setActiveConfiguration(_ config: PowerModeConfig?) {
        activeConfiguration = config
        UserDefaults.standard.set(config?.id.uuidString, forKey: activeConfigIdKey)
        self.objectWillChange.send()
    }

    /// An explicit pick from the recorder. It applies to the recording in progress.
    func selectInRecorder(_ config: PowerModeConfig) {
        setActiveConfiguration(config)
        NotificationCenter.default.post(name: .powerModeSelectedInRecorder, object: config)
    }

    var currentActiveConfiguration: PowerModeConfig? {
        return activeConfiguration
    }

    func getAllAvailableConfigurations() -> [PowerModeConfig] {
        return configurations
    }

    func isEmojiInUse(_ emoji: String) -> Bool {
        return configurations.contains { $0.emoji == emoji }
    }
}
