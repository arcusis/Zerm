import AVFoundation
import Foundation
import NaturalLanguage

/// Picks a voice that can actually pronounce the selected text.
///
/// Kokoro (and Deepgram Aura) are English-only engines. Instead of refusing every other
/// language, Read Aloud detects the dominant language of the text and reroutes to an installed
/// Apple system voice for that language — the only on-device engine that ships with dozens of
/// languages. Apple-voice users who selected, say, an English voice get the matching language
/// voice automatically when they read Hebrew, Russian, or anything else they have installed.
enum TTSLanguageRouter {
    struct Resolution {
        let provider: any TTSProvider
        let voice: TTSVoice
        /// Set when the user's configured provider/voice was replaced for this text.
        let rerouteNotice: String?
    }

    enum RoutingError: LocalizedError {
        case unsupportedLanguage(providerName: String, languageName: String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedLanguage(providerName, languageName):
                let format = String(localized: "%1$@ speaks English only. Install a %2$@ voice in System Settings › Accessibility › Spoken Content, or choose another provider in Read Aloud settings.")
                return String.localizedStringWithFormat(format, providerName, languageName)
            }
        }
    }

    /// BCP-47 language code ("en", "he", "ru", …) of the text, or `nil` when undetermined.
    static func dominantLanguage(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        // Short English fragments are easy to misclassify as a Latin-script neighbour; only
        // accept a non-English Latin result when the recognizer is reasonably confident.
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        let code = language.rawValue
        if !usesNonLatinScript(trimmed), code != "en", confidence < 0.6 { return nil }
        return code
    }

    static func resolve(
        provider: any TTSProvider,
        voice: TTSVoice,
        text: String,
        appleVoices: [TTSVoice]? = nil
    ) throws -> Resolution {
        guard let language = dominantLanguage(of: text) else {
            return Resolution(provider: provider, voice: voice, rerouteNotice: nil)
        }
        let voiceLanguage = languageCode(voice.language)
        if voiceLanguage == language {
            return Resolution(provider: provider, voice: voice, rerouteNotice: nil)
        }

        // A provider that has a voice for this language keeps the user's provider.
        if let match = bestVoice(for: language, in: provider.voices) {
            return Resolution(provider: provider, voice: match, rerouteNotice: nil)
        }

        // Multilingual cloud engines pronounce whatever they are given; keep the user's voice.
        guard provider.kind.speaksEnglishOnly else {
            return Resolution(provider: provider, voice: voice, rerouteNotice: nil)
        }

        let apple = AppleSystemTTSProvider()
        let candidates = appleVoices ?? apple.voices
        if let appleVoice = bestVoice(for: language, in: candidates) {
            let format = String(localized: "%1$@ speaks English only — reading with %2$@")
            return Resolution(
                provider: apple,
                voice: appleVoice,
                rerouteNotice: String.localizedStringWithFormat(format, provider.displayName, appleVoice.displayName)
            )
        }
        throw RoutingError.unsupportedLanguage(
            providerName: provider.displayName,
            languageName: Locale.current.localizedString(forLanguageCode: language) ?? language
        )
    }

    /// Prefers the voice whose region matches the user's locale, then premium/enhanced ones.
    static func bestVoice(for language: String, in voices: [TTSVoice]) -> TTSVoice? {
        let matches = voices.filter { languageCode($0.language) == language }
        guard !matches.isEmpty else { return nil }
        let region = Locale.current.region?.identifier
        let quality: (TTSVoice) -> Int = { voice in
            guard voice.provider == .appleSystem,
                  let system = AVSpeechSynthesisVoice(identifier: voice.id) else { return voice.isPremium ? 1 : 0 }
            return system.quality.rawValue
        }
        return matches.max { lhs, rhs in
            let lhsRegion = Locale(identifier: lhs.language).region?.identifier == region ? 1 : 0
            let rhsRegion = Locale(identifier: rhs.language).region?.identifier == region ? 1 : 0
            if lhsRegion != rhsRegion { return lhsRegion < rhsRegion }
            return quality(lhs) < quality(rhs)
        }
    }

    static func languageCode(_ identifier: String) -> String {
        Locale(identifier: identifier).language.languageCode?.identifier ?? identifier.lowercased()
    }

    private static func usesNonLatinScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) && EnhancementLanguageGuard.script(of: scalar) != .latin
        }
    }
}
