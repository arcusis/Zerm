import Testing
@testable import Zerm

struct LanguagePreferenceTests {

    @Test func autoNormalizesToNilApiLanguage() {
        let defaults = UserDefaults(suiteName: "zerm.tests.language.\(UUID().uuidString)")!
        defaults.set("auto", forKey: LanguagePreference.defaultsKey)
        #expect(LanguagePreference.apiLanguage(defaults: defaults) == nil)
        #expect(LanguagePreference.isAuto(defaults: defaults))
    }

    @Test func englishCodeIsPassedThrough() {
        let defaults = UserDefaults(suiteName: "zerm.tests.language.\(UUID().uuidString)")!
        defaults.set("en", forKey: LanguagePreference.defaultsKey)
        #expect(LanguagePreference.apiLanguage(defaults: defaults) == "en")
        #expect(LanguagePreference.selectedCode(defaults: defaults) == "en")
    }

    @Test func deepgramAutoBecomesMultiForNova3() {
        #expect(DeepgramProvider.resolvedLanguage(nil, model: "nova-3") == "multi")
        #expect(DeepgramProvider.resolvedLanguage("auto", model: "nova-3") == "multi")
        #expect(DeepgramProvider.resolvedLanguage("en", model: "nova-3") == "en")
        #expect(DeepgramProvider.resolvedLanguage(nil, model: "nova-3-medical") == nil)
    }

    @Test func shortHebrewKeyboardMismatchRequestsOneFallback() {
        #expect(WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "auto",
            shouldConsiderHebrew: true,
            detectedLanguage: "en",
            durationSeconds: 4,
            primaryText: "shalom ma shlomcha",
            primaryProbability: 0.78
        ))
    }

    @Test func pinnedLanguageNeverRequestsHebrewFallback() {
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "he",
            shouldConsiderHebrew: true,
            detectedLanguage: "he",
            durationSeconds: 4,
            primaryText: "שלום",
            primaryProbability: 0.9
        ))
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "ru",
            shouldConsiderHebrew: true,
            detectedLanguage: "ru",
            durationSeconds: 4,
            primaryText: "привет как дела",
            primaryProbability: 0.88
        ))
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "en",
            shouldConsiderHebrew: true,
            detectedLanguage: "en",
            durationSeconds: 4,
            primaryText: "please send the report",
            primaryProbability: 0.9
        ))
    }

    @Test func longDictationNeverRequestsHebrewFallback() {
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "auto",
            shouldConsiderHebrew: true,
            detectedLanguage: "en",
            durationSeconds: 8,
            primaryText: "shalom ma shlomcha",
            primaryProbability: 0.78
        ))
    }

    @Test func hebrewFallbackIgnoredWithoutKeyboardPrior() {
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "auto",
            shouldConsiderHebrew: false,
            detectedLanguage: "en",
            durationSeconds: 4,
            primaryText: "shalom ma shlomcha",
            primaryProbability: 0.78
        ))
    }

    @Test func confidentRussianDoesNotPayForHebrewPass() {
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "auto",
            shouldConsiderHebrew: true,
            detectedLanguage: "ru",
            durationSeconds: 4,
            primaryText: "отправь отчет сегодня",
            primaryProbability: 0.86
        ))
    }

    @Test func confidentEnglishSentenceDoesNotPayForHebrewPass() {
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "auto",
            shouldConsiderHebrew: true,
            detectedLanguage: "en",
            durationSeconds: 5,
            primaryText: "Please send the report today and copy the rest of the team.",
            primaryProbability: 0.93
        ))
    }

    @Test func latinHebrewTransliterationCanBeatAnEnglishGuess() {
        let primary = WhisperLanguageCandidateSelector.Candidate(
            text: "shalom ma shlomcha",
            languageCode: "en",
            averageTokenProbability: 0.78
        )
        let hebrew = WhisperLanguageCandidateSelector.Candidate(
            text: "שלום, מה שלומך?",
            languageCode: "he",
            averageTokenProbability: 0.79
        )
        #expect(WhisperLanguageCandidateSelector.choose(primary: primary, hebrew: hebrew) == hebrew)
    }

    @Test func weakerHebrewTransliterationDoesNotReplaceLatinGuess() {
        let primary = WhisperLanguageCandidateSelector.Candidate(
            text: "shalom ma shlomcha",
            languageCode: "en",
            averageTokenProbability: 0.78
        )
        let hebrew = WhisperLanguageCandidateSelector.Candidate(
            text: "שלום, מה שלומך?",
            languageCode: "he",
            averageTokenProbability: 0.70
        )
        #expect(WhisperLanguageCandidateSelector.choose(primary: primary, hebrew: hebrew) == primary)
    }

    @Test func weakHebrewHallucinationDoesNotReplaceStrongAutoResult() {
        let primary = WhisperLanguageCandidateSelector.Candidate(
            text: "Please send the report today.",
            languageCode: "en",
            averageTokenProbability: 0.93
        )
        let hebrew = WhisperLanguageCandidateSelector.Candidate(
            text: "שלח את הדוח היום",
            languageCode: "he",
            averageTokenProbability: 0.41
        )
        #expect(WhisperLanguageCandidateSelector.choose(primary: primary, hebrew: hebrew) == primary)
    }

    @Test func nearTieHebrewDoesNotReplaceConfidentEnglish() {
        let primary = WhisperLanguageCandidateSelector.Candidate(
            text: "Please send the report today and follow up tomorrow.",
            languageCode: "en",
            averageTokenProbability: 0.86
        )
        let hebrew = WhisperLanguageCandidateSelector.Candidate(
            text: "שלח את הדוח היום ותעקוב מחר",
            languageCode: "he",
            averageTokenProbability: 0.84
        )
        #expect(WhisperLanguageCandidateSelector.choose(primary: primary, hebrew: hebrew) == primary)
    }

    @Test func confidentRussianIsNeverReplacedByHebrew() {
        let primary = WhisperLanguageCandidateSelector.Candidate(
            text: "отправь отчет сегодня",
            languageCode: "ru",
            averageTokenProbability: 0.82
        )
        let hebrew = WhisperLanguageCandidateSelector.Candidate(
            text: "שלח את הדוח היום",
            languageCode: "he",
            averageTokenProbability: 0.81
        )
        #expect(WhisperLanguageCandidateSelector.choose(primary: primary, hebrew: hebrew) == primary)
    }
}
