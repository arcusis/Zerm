import Testing
@testable import Zerm

struct OutputFilterTests {

    @Test func enhancementStripsLeakedGemmaTurnTokens() {
        let input = "</start_of_turn>Clean technical transcript.<end_of_turn>"
        #expect(AIEnhancementOutputFilter.filter(input) == "Clean technical transcript.")
    }

    @Test func enhancementStripsCommonChatTemplateTokensWithoutChangingTechnicalText() {
        let input = "<|im_start|>DigitalOcean CLI uses `doctl`.<|im_end|>"
        #expect(AIEnhancementOutputFilter.filter(input) == "DigitalOcean CLI uses `doctl`.")
    }

    @Test func builtInTechnicalVocabularyIsScopedToCoding() {
        let coding = TechnicalTerminology.terms(for: PredefinedPrompts.codingPromptId)
        #expect(coding.contains("DigitalOcean"))
        #expect(coding.contains("Codex"))
        #expect(coding.contains("Claude Code"))
        #expect(coding.contains("Gemini"))
        #expect(coding.contains("CLI"))
        #expect(TechnicalTerminology.terms(for: PredefinedPrompts.defaultPromptId).isEmpty)
    }

    @Test func codingPromptHandlesAmbiguousProductNamesUsingContext() throws {
        let prompt = try #require(PromptTemplates.all.first { $0.title == "Coding" }?.promptText)
        #expect(prompt.contains("DigitalOcean CLI"))
        #expect(prompt.contains("Codex only"))
        #expect(prompt.contains("Claude Code only"))
        #expect(prompt.contains("SwiftUI"))
    }

    @Test func keepsLegitimateParentheticals() {
        let input = "the total (about five hundred) looks fine"
        let out = TranscriptionOutputFilter.filter(input)
        #expect(out.contains("(about five hundred)"))
        #expect(out.contains("five hundred"))
    }

    @Test func stripsKnownHallucinationTokens() {
        let input = "hello [BLANK_AUDIO] world [Music] there"
        let out = TranscriptionOutputFilter.filter(input)
        #expect(!out.contains("BLANK_AUDIO"))
        #expect(!out.contains("Music"))
        #expect(out.contains("hello"))
        #expect(out.contains("world"))
    }

    @Test func removesTrailingPeriodWhenConfigured() {
        let out = TranscriptionOutputFilter.applyCleanupPreferences(
            "Hello world.",
            punctuationMode: .removeTrailingPeriod,
            shouldLowercase: false
        )
        #expect(out == "Hello world")
    }

    @Test func lowercasesWhenConfigured() {
        let out = TranscriptionOutputFilter.applyCleanupPreferences(
            "Hello World",
            punctuationMode: .keep,
            shouldLowercase: true
        )
        #expect(out == "hello world")
    }
}
