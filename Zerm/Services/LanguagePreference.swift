import Carbon
import Foundation

/// Single source of truth for SelectedLanguage normalization across engines.
enum LanguagePreference {
    /// Per-operation override used by long-running jobs that snapshot settings at creation.
    /// Task-local scope avoids mutating global defaults while another dictation is running.
    @TaskLocal static var operationOverrideCode: String?

    static let defaultsKey = "SelectedLanguage"

    /// The stored value meaning "let the engine detect the language".
    static let autoCode = "auto"

    /// Raw stored value (`"auto"`, `"en"`, …).
    static func selectedCode(defaults: UserDefaults = .standard) -> String {
        if let operationOverrideCode, !operationOverrideCode.isEmpty {
            return operationOverrideCode
        }
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

    /// A strong, operation-local hint for ambiguous short dictation.
    ///
    /// Whisper remains responsible for automatic language detection. The current keyboard
    /// language is consulted only when that first pass disagrees and Zerm can compare a second
    /// candidate. This avoids turning the keyboard layout into a hidden fixed-language setting
    /// while giving short Hebrew phrases enough prior signal to recover from an English guess.
    @MainActor
    static func currentInputSourceLanguageCode() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let languagesRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let languages = Unmanaged<CFArray>.fromOpaque(languagesRef).takeUnretainedValue() as? [String]
        guard let identifier = languages?.first else { return nil }
        return Locale(identifier: identifier).language.languageCode?.identifier
    }

    /// Whether a forced-Hebrew Whisper pass is even worth considering.
    ///
    /// Only the active keyboard is a dictation prior. Having Hebrew in macOS preferred
    /// languages — or using the Hebrew UI — is not: that used to run a second `he` pass on
    /// every short Auto dictation and let hallucinated Hebrew beat English or Russian.
    @MainActor
    static func prefersHebrewForAutomaticDetection() -> Bool {
        currentInputSourceLanguageCode() == "he"
    }
}

/// Pure decision layer for Whisper's automatic-language recovery pass.
/// Kept independent of the C runtime so the Hebrew selection contract is deterministic in tests.
enum WhisperLanguageCandidateSelector {
    struct Candidate: Equatable {
        let text: String
        let languageCode: String?
        let averageTokenProbability: Float
    }

    static func shouldEvaluateFallback(
        selectedLanguage: String,
        shouldConsiderHebrew: Bool,
        detectedLanguage: String?,
        durationSeconds: Double,
        primaryText: String = "",
        primaryProbability: Float = 0
    ) -> Bool {
        guard selectedLanguage == LanguagePreference.autoCode,
              shouldConsiderHebrew,
              detectedLanguage != "he",
              durationSeconds > 0.25,
              durationSeconds <= 6 else {
            return false
        }

        // A confident non-English, non-Hebrew detection is already a language decision.
        // Running forced-`he` on Russian (or Arabic, French, …) is how Hebrew leaked into
        // speech that never contained it.
        if isIdentifiedNonEnglishLanguage(detectedLanguage),
           primaryProbability >= 0.70 {
            return false
        }

        let trimmed = primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        // Confident multi-word English is not a Hebrew-transliteration miss.
        if detectedLanguage == "en",
           primaryProbability >= 0.88,
           wordCount(in: trimmed) >= 8,
           latinLetterRatio(in: trimmed) >= 0.90 {
            return false
        }

        return looksLikeLatinLetterTranscript(trimmed)
    }

    static func choose(primary: Candidate, hebrew: Candidate) -> Candidate {
        let primaryText = primary.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hebrewText = hebrew.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hebrewText.isEmpty else { return primary }
        if primaryText.isEmpty { return hebrew }

        let primaryHebrewRatio = hebrewLetterRatio(in: primaryText)
        let fallbackHebrewRatio = hebrewLetterRatio(in: hebrewText)
        guard fallbackHebrewRatio >= 0.35, primaryHebrewRatio < 0.10 else {
            return primary
        }

        if isIdentifiedNonEnglishLanguage(primary.languageCode),
           primary.averageTokenProbability >= 0.70 {
            return primary
        }

        let primaryLooksLikeTransliteration = looksLikeLatinLetterTranscript(primaryText)
            && primary.averageTokenProbability < 0.85
            && wordCount(in: primaryText) <= 12

        if primaryLooksLikeTransliteration {
            // Short Latin output on a Hebrew keyboard is the recovery case
            // ("shalom ma shlomcha" vs "שלום, מה שלומך?"). Hebrew may win on a
            // near-tie; it must still be at least as probable.
            return hebrew.averageTokenProbability + 0.01 >= primary.averageTokenProbability
                ? hebrew
                : primary
        }

        // Confident English / long Latin must be clearly beaten, not matched.
        guard hebrew.averageTokenProbability >= primary.averageTokenProbability + 0.08 else {
            return primary
        }
        return hebrew
    }

    private static func isIdentifiedNonEnglishLanguage(_ code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        return code != "he" && code != "en" && code != LanguagePreference.autoCode
    }

    private static func looksLikeLatinLetterTranscript(_ text: String) -> Bool {
        latinLetterRatio(in: text) >= 0.80
    }

    private static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func hebrewLetterRatio(in text: String) -> Double {
        letterRatio(in: text, matching: { (0x0590...0x05FF).contains($0.value) })
    }

    private static func latinLetterRatio(in text: String) -> Double {
        letterRatio(in: text, matching: isLatinLetter)
    }

    private static func letterRatio(
        in text: String,
        matching isMatch: (Unicode.Scalar) -> Bool
    ) -> Double {
        var letters = 0
        var matched = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if isMatch(scalar) {
                matched += 1
            }
        }
        guard letters > 0 else { return 0 }
        return Double(matched) / Double(letters)
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x0041...0x005A).contains(value)
            || (0x0061...0x007A).contains(value)
            || (0x00C0...0x024F).contains(value)
            || (0x1E00...0x1EFF).contains(value)
            || (0x2C60...0x2C7F).contains(value)
            || (0xA720...0xA7FF).contains(value)
    }
}

/// Process-wide "we are shutting down (or must not start native work)" flag.
///
/// Native ML runtimes (onnxruntime via sherpa-onnx, llama.cpp) read C++ global registries while
/// constructing a session. If `exit()` runs concurrently, `__cxa_finalize_ranges` tears those
/// globals down mid-construction and the load segfaults. None of that work is cancellable once
/// it has entered the C++ library, so background prewarm tasks check this before starting.
enum ProcessLifecycle {
    nonisolated(unsafe) static var isTerminating = false
}
