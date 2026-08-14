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

    /// Whether Hebrew is a reasonable second-pass candidate for this user. Keyboard layout is
    /// the strongest signal, but bilingual users often dictate Hebrew while an English layout is
    /// still active; the macOS preferred-language list keeps Auto useful in that common case.
    @MainActor
    static func prefersHebrewForAutomaticDetection() -> Bool {
        if currentInputSourceLanguageCode() == "he" { return true }
        return Locale.preferredLanguages.contains {
            Locale(identifier: $0).language.languageCode?.identifier == "he"
        }
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
        durationSeconds: Double
    ) -> Bool {
        selectedLanguage == LanguagePreference.autoCode
            && shouldConsiderHebrew
            && detectedLanguage != "he"
            && durationSeconds > 0.25
            && durationSeconds <= 20
    }

    static func choose(primary: Candidate, hebrew: Candidate) -> Candidate {
        let primaryText = primary.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hebrewText = hebrew.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hebrewText.isEmpty else { return primary }
        if primaryText.isEmpty { return hebrew }

        let primaryHebrewRatio = hebrewLetterRatio(in: primaryText)
        let fallbackHebrewRatio = hebrewLetterRatio(in: hebrewText)
        let fallbackIsCredible = hebrew.averageTokenProbability + 0.04 >= primary.averageTokenProbability

        guard fallbackHebrewRatio >= 0.35,
              primaryHebrewRatio < 0.10,
              fallbackIsCredible else {
            return primary
        }
        return hebrew
    }

    private static func hebrewLetterRatio(in text: String) -> Double {
        var letters = 0
        var hebrewLetters = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if (0x0590...0x05FF).contains(scalar.value) {
                hebrewLetters += 1
            }
        }
        guard letters > 0 else { return 0 }
        return Double(hebrewLetters) / Double(letters)
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
