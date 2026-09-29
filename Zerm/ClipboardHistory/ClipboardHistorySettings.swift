import Foundation

enum ClipboardPanelPosition: String, CaseIterable, Identifiable {
    case lastLocation
    case centerScreen
    case pointer

    var id: String { rawValue }
}

enum ClipboardHistorySoundChoice: Equatable {
    case none
    case system(String)
    case custom(Data)

    init(storageValue: String) {
        if storageValue == "none" { self = .none }
        else if storageValue.hasPrefix("system:") { self = .system(String(storageValue.dropFirst(7))) }
        else if storageValue.hasPrefix("custom:"), let data = Data(base64Encoded: String(storageValue.dropFirst(7))) { self = .custom(data) }
        else { self = .none }
    }

    static func customFile(_ url: URL) -> ClipboardHistorySoundChoice {
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return .custom(bookmark ?? Data(url.absoluteString.utf8))
    }

    var storageValue: String {
        switch self {
        case .none: "none"
        case .system(let name): "system:\(name)"
        case .custom(let data): "custom:\(data.base64EncodedString())"
        }
    }

    var customURL: URL? {
        guard case .custom(let data) = self else { return nil }
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) { return url }
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: value)
    }
}

enum ClipboardHistorySettings {
    enum Keys {
        static let enabled = "clipboardHistoryEnabled"
        static let windowPosition = "ClipboardHistoryWindowPosition"
        static let pasteOnClick = "clipboardHistoryPasteOnClick"
        static let doubleClickPaste = "clipboardHistoryDoubleClickPaste"
        static let showBadges = "clipboardHistoryShowBadges"
        static let updateAfterPaste = "clipboardHistoryUpdateAfterPaste"
        static let favoritesOnTop = "clipboardHistoryFavoritesOnTop"
        static let warnBeforeClear = "clipboardHistoryWarnBeforeClear"
        static let clearOnQuit = "clipboardHistoryClearOnQuit"
        static let clearOnRestart = "clipboardHistoryClearOnRestart"
        static let clearOnLock = "clipboardHistoryClearOnLock"
        static let clearOnSleep = "clipboardHistoryClearOnSleep"
        static let clearDaily = "clipboardHistoryClearDaily"
        static let clearDailyTime = "clipboardHistoryClearDailyTime"
        static let lastDailyClear = "clipboardHistoryLastDailyClear"
        static let maximumStorageSize = "clipboardHistoryMaximumStorageSize"
        static let keepFavoritesOnClear = "clipboardHistoryKeepFavoritesOnClear"
        static let keepTaggedOnClear = "clipboardHistoryKeepTaggedOnClear"
        static let ignoreConfidential = "clipboardHistoryIgnoreConfidential"
        static let ignoreTransient = "clipboardHistoryIgnoreTransient"
        static let retentionCount = "clipboardHistoryRetentionCount"
        static let maximumItemSize = "clipboardHistoryMaximumItemSize"
        static let retentionByKind = "clipboardHistoryRetentionByKind"
        static let maximumSizeByKind = "clipboardHistoryMaximumSizeByKind"
        static let sort = "clipboardHistorySort"
        static let copyMergeEnabled = "clipboardHistoryCopyMergeEnabled"
        static let copyMergeSeparator = "clipboardHistoryCopyMergeSeparator"
        static let copyMergeUpdatesClipboard = "clipboardHistoryCopyMergeUpdatesClipboard"
        static let excludedApps = "clipboardHistoryExcludedApps"
        static let saveDictations = "clipboardHistorySaveDictations"
        static let sounds = "clipboardHistorySounds"
        static let paused = "clipboardHistoryPaused"
        static let copySound = "clipboardHistoryCopySound"
        static let pasteSound = "clipboardHistoryPasteSound"
        static let deleteSound = "clipboardHistoryDeleteSound"
        static let selectionSound = "clipboardHistorySelectionSound"
        static let linkPreviewsEnabled = "clipboardHistoryLinkPreviewsEnabled"
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }
    static var retentionCount: Int {
        get { retentionCount(in: .standard) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: Keys.retentionCount) }
    }
    static func retentionCount(in defaults: UserDefaults) -> Int {
        max(1, defaults.object(forKey: Keys.retentionCount) as? Int ?? 500)
    }
    static var maximumItemSize: Int {
        get { maximumItemSize(in: .standard) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: Keys.maximumItemSize) }
    }
    static var maximumStorageSize: Int64 {
        get { maximumStorageSize(in: .standard) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: Keys.maximumStorageSize) }
    }
    static func maximumStorageSize(in defaults: UserDefaults) -> Int64 {
        let value = defaults.object(forKey: Keys.maximumStorageSize) as? NSNumber
        return max(1, value?.int64Value ?? 1_073_741_824)
    }
    static func maximumItemSize(in defaults: UserDefaults) -> Int {
        max(1, defaults.object(forKey: Keys.maximumItemSize) as? Int ?? 50 * 1_024 * 1_024)
    }
    static var maximumSizeByKind: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: Keys.maximumSizeByKind) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.maximumSizeByKind) }
    }
    static func maximumSizeByKind(in defaults: UserDefaults) -> [String: Int] {
        defaults.dictionary(forKey: Keys.maximumSizeByKind) as? [String: Int] ?? [:]
    }
    static var windowPosition: String {
        get { UserDefaults.standard.string(forKey: Keys.windowPosition) ?? "lastLocation" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.windowPosition) }
    }
    static var panelPosition: ClipboardPanelPosition {
        get { ClipboardPanelPosition(rawValue: windowPosition) ?? .lastLocation }
        set { windowPosition = newValue.rawValue }
    }
    static func bool(_ key: String, defaultValue: Bool = false) -> Bool {
        bool(key, in: .standard, defaultValue: defaultValue)
    }
    static func bool(_ key: String, in defaults: UserDefaults, defaultValue: Bool = false) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
    static func set(_ value: Bool, for key: String) { UserDefaults.standard.set(value, forKey: key) }
    static var excludedApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.excludedApps) ?? Self.defaultExcludedApps) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Keys.excludedApps) }
    }
    static var saveDictations: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.saveDictations) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.saveDictations) }
    }
    static var soundsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.sounds) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sounds) }
    }
    static var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.paused) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.paused) }
    }

    static func soundChoice(for key: String, fallback: String) -> ClipboardHistorySoundChoice {
        if let value = UserDefaults.standard.string(forKey: key) { return ClipboardHistorySoundChoice(storageValue: value) }
        return bool(key) ? .system(fallback) : .none
    }
    static func soundEnabled(for key: String) -> Bool { soundChoice(for: key, fallback: "Pop") != .none }

    static let defaultExcludedApps: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.Passwords",
        "com.apple.keychainaccess"
    ]
}

enum ClipboardExclusionPolicy {
    static let excludedPasteboardTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType"
    ]

    static func excludes(
        types: some Sequence<String>,
        sourceBundleIdentifier: String?,
        excludedApps: Set<String>,
        ignoreConfidential: Bool = true,
        ignoreTransient: Bool = true
    ) -> Bool {
        let typeSet = Set(types)
        let hasConfidential = typeSet.contains("org.nspasteboard.ConcealedType")
        let hasTransient = typeSet.contains("org.nspasteboard.TransientType")
            || typeSet.contains("org.nspasteboard.AutoGeneratedType")
        return (ignoreConfidential && hasConfidential)
            || (ignoreTransient && hasTransient)
            || (sourceBundleIdentifier.map(excludedApps.contains) ?? false)
            || typeSet.contains(ClipboardManager.historyIgnoreType.rawValue)
            || typeSet.contains(ClipboardManager.pasteSessionType.rawValue)
    }
}
