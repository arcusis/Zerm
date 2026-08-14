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
            durationSeconds: 4
        ))
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "he",
            shouldConsiderHebrew: true,
            detectedLanguage: "he",
            durationSeconds: 4
        ))
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "auto",
            shouldConsiderHebrew: true,
            detectedLanguage: "en",
            durationSeconds: 30
        ))
    }

    @Test func credibleHebrewCandidateWinsOverLatinAutoGuess() {
        let primary = WhisperLanguageCandidateSelector.Candidate(
            text: "shalom ma shlomcha",
            languageCode: "en",
            averageTokenProbability: 0.78
        )
        let hebrew = WhisperLanguageCandidateSelector.Candidate(
            text: "שלום, מה שלומך?",
            languageCode: "he",
            averageTokenProbability: 0.76
        )
        #expect(WhisperLanguageCandidateSelector.choose(primary: primary, hebrew: hebrew) == hebrew)
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
}
