import Foundation

/// Turns Zerm's provider-neutral language preference into a locale Apple Speech supports.
enum SpeechLocaleResolver {
    /// Resolves `requestedCode` (a locale, a base language or `auto`) against the supported
    /// identifiers: an exact match first, then the current or conventional locale for the same
    /// language, and finally the current locale's language or `en-US`.
    static func localeCode(
        requestedCode: String,
        supportedIdentifiers: [String],
        locale: Locale = .current
    ) -> String {
        let supported = Array(Set(supportedIdentifiers)).sorted()
        guard !supported.isEmpty else { return "en-US" }

        if requestedCode != LanguagePreference.autoCode, !requestedCode.isEmpty {
            if let exact = exactLocaleCode(requestedCode: requestedCode, supportedIdentifiers: supported) {
                return exact
            }
            let requestedLanguage = Locale(identifier: requestedCode).language.languageCode?.identifier
            let candidates = supported.filter {
                Locale(identifier: $0).language.languageCode?.identifier == requestedLanguage
            }
            if !candidates.isEmpty {
                let currentIdentifier = locale.identifier(.bcp47)
                if let current = candidates.first(where: {
                    $0.caseInsensitiveCompare(currentIdentifier) == .orderedSame
                }) {
                    return current
                }
                let conventional: [String: String] = [
                    "ar": "ar-SA", "de": "de-DE", "en": "en-US", "es": "es-ES",
                    "fr": "fr-FR", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR",
                    "pt": "pt-BR", "yue": "yue-CN", "zh": "zh-CN",
                ]
                if let preferred = requestedLanguage.flatMap({ conventional[$0] }),
                   candidates.contains(preferred) {
                    return preferred
                }
                return candidates[0]
            }
        }

        let currentIdentifier = locale.identifier(.bcp47)
        if let exactCurrent = exactLocaleCode(requestedCode: currentIdentifier, supportedIdentifiers: supported) {
            return exactCurrent
        }
        let currentLanguage = locale.language.languageCode?.identifier
        if let sameLanguage = supported.first(where: {
            Locale(identifier: $0).language.languageCode?.identifier == currentLanguage
        }) {
            return sameLanguage
        }
        return supported.contains("en-US") ? "en-US" : supported[0]
    }

    /// The supported identifier matching `requestedCode` exactly (case-insensitively), or nil.
    static func exactLocaleCode(
        requestedCode: String,
        supportedIdentifiers: [String]
    ) -> String? {
        supportedIdentifiers.first {
            $0.caseInsensitiveCompare(requestedCode) == .orderedSame
        }
    }
}
