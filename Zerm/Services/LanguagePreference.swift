import Foundation

/// Single source of truth for SelectedLanguage normalization across engines.
enum LanguagePreference {
    static let defaultsKey = "SelectedLanguage"

    /// Raw stored value (`"auto"`, `"en"`, …).
    static func selectedCode(defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: defaultsKey) ?? "auto"
        return raw.isEmpty ? "auto" : raw
    }

    /// `nil` when auto-detect; otherwise the language code for APIs that omit param = auto.
    static func apiLanguage(defaults: UserDefaults = .standard) -> String? {
        let code = selectedCode(defaults: defaults)
        if code == "auto" || code.isEmpty { return nil }
        return code
    }

    /// True when the user wants automatic language detection.
    static func isAuto(defaults: UserDefaults = .standard) -> Bool {
        apiLanguage(defaults: defaults) == nil
    }
}
