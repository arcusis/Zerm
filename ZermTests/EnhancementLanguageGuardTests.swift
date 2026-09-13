import Testing
@testable import Zerm

struct EnhancementLanguageGuardTests {

    @Test func mixedHebrewAndEnglishStaysAcceptableWhenBothScriptsRemain() {
        let original = "Let's meet tomorrow בבוקר and then send the report."
        let enhanced = "Let's meet tomorrow בבוקר, and then send the report."
        #expect(EnhancementLanguageGuard.accept(original: original, enhanced: enhanced))
    }

    @Test func collapsingMixedInputToHebrewIsRejected() {
        let original = "Let's meet tomorrow בבוקר and then send the report."
        let enhanced = "בוא ניפגש מחר בבוקר ואז נשלח את הדוח."
        #expect(!EnhancementLanguageGuard.accept(original: original, enhanced: enhanced))
    }

    @Test func russianAndEnglishMustNotGrowHebrew() {
        let original = "Отправь the report сегодня please"
        let enhanced = "שלח את הדוח היום בבקשה"
        #expect(!EnhancementLanguageGuard.accept(original: original, enhanced: enhanced))
    }

    @Test func hebrewOnlyRemainsHebrew() {
        let original = "אממ אני רוצה לקבוע את פגישת המוצר ביום שני"
        let enhanced = "אני רוצה לקבוע את פגישת המוצר ביום שני."
        #expect(EnhancementLanguageGuard.accept(original: original, enhanced: enhanced))
    }

    @Test func englishOnlyRemainsEnglish() {
        let original = "okay so um send the report today"
        let enhanced = "Send the report today."
        #expect(EnhancementLanguageGuard.accept(original: original, enhanced: enhanced))
    }

    @Test func englishOnlyMustNotBecomeHebrew() {
        let original = "send the report today"
        let enhanced = "שלח את הדוח היום"
        #expect(!EnhancementLanguageGuard.accept(original: original, enhanced: enhanced))
    }

    @Test func englishMustNotGrowAHebrewPrefix() {
        let original = "send the report today"
        let enhanced = "שלח the report today."
        #expect(!EnhancementLanguageGuard.accept(original: original, enhanced: enhanced))
    }

    @Test func hebrewMajorityMixedMustNotCollapseToHebrewOnly() {
        let original = "צריך לשלוח the report היום לצוות המוצר"
        let enhanced = "צריך לשלוח את הדוח היום לצוות המוצר"
        #expect(!EnhancementLanguageGuard.accept(original: original, enhanced: enhanced))
    }

    @Test func translationPromptsMayChangeTheScript() {
        let original = "send the report today"
        let translated = "שלח את הדוח היום"
        #expect(EnhancementLanguageGuard.rejection(original: original, enhanced: translated, policy: .preserveScript) == .languageChanged)
        #expect(EnhancementLanguageGuard.rejection(original: original, enhanced: translated, policy: .mayChangeLanguage) == nil)
    }

    @Test func expansionPromptsAreNotCappedAtFourTimesTheInput() {
        let original = "email bob about friday"
        let email = String(repeating: "Hi Bob, just a note about the Friday meeting and the agenda for it. ", count: 4)
        #expect(EnhancementLanguageGuard.rejection(original: original, enhanced: email, policy: .preserveScript) == .tooLong)
        #expect(EnhancementLanguageGuard.rejection(original: original, enhanced: email, policy: .mayChangeLanguage) == nil)
    }

    @Test func emptySidesAreAcceptedSoCallersCanHandleThem() {
        #expect(EnhancementLanguageGuard.accept(original: "", enhanced: "hello"))
        #expect(EnhancementLanguageGuard.accept(original: "hello", enhanced: ""))
    }

    @Test func enhancementPromptDoesNotNameHebrewOrAskForAPredominantLanguage() {
        #expect(!AIPrompts.customPromptTemplate.localizedCaseInsensitiveContains("hebrew"))
        #expect(!AIPrompts.customPromptTemplate.localizedCaseInsensitiveContains("predominant"))
        #expect(AIPrompts.customPromptTemplate.contains("original script"))
    }

    @Test func gemmaSelfIntroductionIsNeverUsable() {
        let original = "okay so um send the report today"
        let leaked = "I am Gemma 4, a Large Language Model developed by Google DeepMind. I am an open weights model."
        #expect(EnhancementLanguageGuard.looksLikeSelfIntroduction(leaked, original: original))
        #expect(!EnhancementLanguageGuard.isUsable(original: original, enhanced: leaked))
    }

    @Test func cleanedEnglishIsStillUsable() {
        let original = "okay so um send the report today"
        let enhanced = "Send the report today."
        #expect(EnhancementLanguageGuard.isUsable(original: original, enhanced: enhanced))
    }

    @Test func mentioningGemmaIsAllowedWhenTheSpeakerSaidIt() {
        let original = "ask Gemma to rewrite this"
        let enhanced = "Ask Gemma to rewrite this."
        #expect(EnhancementLanguageGuard.isUsable(original: original, enhanced: enhanced))
    }
}
