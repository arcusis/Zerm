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

/// Hebrew and Russian dictation came out as Arabic; the language the user chose must win (#370).
struct LanguageSelectionFixTests {

    @Test func arabicOnAHebrewKeyboardGetsAHebrewPass() {
        #expect(WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "auto",
            shouldConsiderHebrew: true,
            detectedLanguage: "ar",
            durationSeconds: 3,
            primaryText: "شكرا جزيلا",
            primaryProbability: 0.9
        ))
    }

    @Test func hebrewBeatsAnArabicGuessUnlessClearlyLessLikely() {
        let arabic = WhisperLanguageCandidateSelector.Candidate(text: "شكرا جزيلا", languageCode: "ar", averageTokenProbability: 0.85)
        let closeHebrew = WhisperLanguageCandidateSelector.Candidate(text: "תודה רבה", languageCode: "he", averageTokenProbability: 0.82)
        let weakHebrew = WhisperLanguageCandidateSelector.Candidate(text: "תודה רבה", languageCode: "he", averageTokenProbability: 0.6)
        #expect(WhisperLanguageCandidateSelector.choose(primary: arabic, hebrew: closeHebrew) == closeHebrew)
        #expect(WhisperLanguageCandidateSelector.choose(primary: arabic, hebrew: weakHebrew) == arabic)
    }

    @Test func confidentRussianIsStillLeftAlone() {
        #expect(!WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: "auto",
            shouldConsiderHebrew: true,
            detectedLanguage: "ru",
            durationSeconds: 3,
            primaryText: "Большое спасибо",
            primaryProbability: 0.9
        ))
    }

    @Test func modelsAreOnlyAskedForLanguagesTheyList() throws {
        let voxtral = try #require(TranscriptionModelRegistry.models.first { $0.name == "voxtral-mini-2602" })
        let gpt = try #require(TranscriptionModelRegistry.models.first { $0.name == "gpt-transcribe" })
        #expect(voxtral.requestLanguage(for: "he") == nil)
        #expect(!voxtral.supportsLanguage("he"))
        #expect(voxtral.requestLanguage(for: "ru") == "ru")
        #expect(gpt.requestLanguage(for: "he") == "he")
        #expect(gpt.requestLanguage(for: "auto") == nil)
        #expect(gpt.supportsLanguage("auto"))
    }

    @Test func storedAutoLanguageIsClearedFromPowerModesOnce() throws {
        let suite = "zerm.tests.auto-language.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configs: [[String: Any]] = [
            ["id": UUID().uuidString, "name": "General", "selectedLanguage": "auto"],
            ["id": UUID().uuidString, "name": "Hebrew mail", "selectedLanguage": "he"],
            ["id": UUID().uuidString, "name": "Code"]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: configs), forKey: PowerModeManager.configKey)

        PowerModeMigration.clearStoredAutoLanguage(defaults: defaults)

        let data = try #require(defaults.data(forKey: PowerModeManager.configKey))
        let migrated = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(migrated[0]["selectedLanguage"] is NSNull)
        #expect(migrated[1]["selectedLanguage"] as? String == "he")
        #expect(migrated[2]["selectedLanguage"] == nil)
        #expect(defaults.integer(forKey: PowerModeMigration.autoLanguageCompletionKey) == 1)

        // A later explicit Auto choice survives: the migration runs once.
        var again = migrated
        again[0]["selectedLanguage"] = "auto"
        defaults.set(try JSONSerialization.data(withJSONObject: again), forKey: PowerModeManager.configKey)
        PowerModeMigration.clearStoredAutoLanguage(defaults: defaults)
        let keptData = try #require(defaults.data(forKey: PowerModeManager.configKey))
        let kept = try #require(try JSONSerialization.jsonObject(with: keptData) as? [[String: Any]])
        #expect(kept[0]["selectedLanguage"] as? String == "auto")
    }
}

/// "My languages" limits Auto-detect to the user's languages (#371).
struct DictationLanguagesTests {
    private let probabilities: [String: Float] = ["ar": 0.46, "he": 0.30, "en": 0.12, "ru": 0.08]

    @Test func aLanguageOutsideTheSetNeverWins() {
        #expect(DictationLanguages.choose(probabilities: probabilities, allowed: ["he", "en", "ru"], keyboardLanguage: nil) == "he")
    }

    @Test func theKeyboardLanguageWinsANearTieWithinTheSet() {
        let close: [String: Float] = ["en": 0.40, "he": 0.34]
        #expect(DictationLanguages.choose(probabilities: close, allowed: ["he", "en"], keyboardLanguage: "he") == "he")
        #expect(DictationLanguages.choose(probabilities: close, allowed: ["he", "en"], keyboardLanguage: "en") == "en")
        let clear: [String: Float] = ["en": 0.80, "he": 0.10]
        #expect(DictationLanguages.choose(probabilities: clear, allowed: ["he", "en"], keyboardLanguage: "he") == "en")
    }

    @Test func noAllowedProbabilityMeansNoChoice() {
        #expect(DictationLanguages.choose(probabilities: probabilities, allowed: ["fr"], keyboardLanguage: nil) == nil)
        #expect(DictationLanguages.choose(probabilities: probabilities, allowed: [], keyboardLanguage: "he") == nil)
    }

    @Test func storageDropsAutoAndDuplicates() {
        #expect(DictationLanguages.encode(["he", "auto", "en", "he"]) == "he,en")
        #expect(DictationLanguages.parse(" he, ,en,auto") == ["he", "en"])
    }
}
