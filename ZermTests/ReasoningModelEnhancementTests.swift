import Testing
@testable import Zerm

/// Regression cover for the 2.8.3 defect where every on-device enhancement returned an empty
/// string and every affected History row rendered blank.
///
/// Qwen3 opens its assistant turn with `<think>`. `LlamaBridge` treated that as a stop
/// delimiter and erased the buffer from the match onward, so generation ended at offset 0
/// before a single answer token was produced. The pipeline then stored `""` over a perfectly
/// good transcript, and `enhancedText ?? text` drew the empty string instead of the words.
struct ReasoningModelEnhancementTests {

    // MARK: - Reasoning output must survive as its answer

    @Test func closedReasoningBlockKeepsTheAnswerThatFollowsIt() {
        let input = "<think>The user said 'gonna'. Tidy it.</think>I am going to send the report."
        #expect(AIEnhancementOutputFilter.filter(input) == "I am going to send the report.")
    }

    @Test func emptyReasoningPrefillLeavesTheAnswerIntact() {
        // What the assistant-turn prefill produces once thinking is suppressed.
        let input = "<think>\n\n</think>\n\nI am going to send the report."
        #expect(AIEnhancementOutputFilter.filter(input) == "I am going to send the report.")
    }

    @Test func multilineReasoningIsStrippedWithoutTouchingTheAnswer() {
        let input = """
        <think>
        First clean the filler.
        Then fix the punctuation.
        </think>
        Ship the build on Friday.
        """
        #expect(AIEnhancementOutputFilter.filter(input) == "Ship the build on Friday.")
    }

    /// An unterminated block ran out of budget mid-thought — there is no answer after it, so
    /// leaking the raw chain-of-thought into the user's cursor is the worst possible outcome.
    @Test func unterminatedReasoningBlockIsDiscardedRatherThanPasted() {
        let input = "<think>The user probably meant to say that the meeting is on"
        #expect(AIEnhancementOutputFilter.filter(input).isEmpty)
    }

    @Test func unterminatedReasoningAfterAnAnswerKeepsTheAnswer() {
        let input = "Ship the build on Friday.<think>Should I also mention the"
        #expect(AIEnhancementOutputFilter.filter(input) == "Ship the build on Friday.")
    }

    @Test func ordinaryTextIsNotMistakenForReasoning() {
        let input = "I think we should ship on Friday."
        #expect(AIEnhancementOutputFilter.filter(input) == "I think we should ship on Friday.")
    }

    // MARK: - Prompt scaffolding must never reach the user's cursor

    @Test func echoedTranscriptTagsAreStrippedButTheTextInsideSurvives() {
        let input = "<TRANSCRIPT>\nShip the build on Friday.\n</TRANSCRIPT>"
        #expect(AIEnhancementOutputFilter.filter(input) == "Ship the build on Friday.")
    }

    @Test func echoedContextSectionTagsAreStripped() {
        let input = "<CLIPBOARD_CONTEXT>\nShip the build on Friday."
        #expect(AIEnhancementOutputFilter.filter(input) == "Ship the build on Friday.")
    }

    @Test func reasoningAndTranscriptTagsAreStrippedTogether() {
        let input = "<think>tidy it</think>\n<TRANSCRIPT>Ship the build on Friday.</TRANSCRIPT>"
        #expect(AIEnhancementOutputFilter.filter(input) == "Ship the build on Friday.")
    }

    @Test func ordinaryAngleBracketedTextIsNotStripped() {
        let input = "Set the header to <div> and ship it."
        #expect(AIEnhancementOutputFilter.filter(input) == "Set the header to <div> and ship it.")
    }

    // MARK: - Reasoning handling stays live even with no reasoning model shipped

    /// Nothing shipped sets this today: the catalogue's only Qwen3 build is the 2507 *Instruct*
    /// release, whose template has no `enable_thinking` switch, so prefilling one would push
    /// tokens it never expects. The flag must never be inferred from the file name.
    @Test func noCatalogueModelPrefillsAReasoningBlockItsTemplateDoesNotSupport() {
        for package in LocalLLMModelManager.packages {
            #expect(!package.disablesThinking, "\(package.fileName)")
        }
    }

    /// The bridge's reasoning-skip must keep working regardless of the catalogue: a user's own
    /// Ollama or Local-CLI model can still open a `<think>` block.
    @Test func reasoningSkipStaysLiveIndependentOfTheCatalog() {
        #expect(AIEnhancementOutputFilter.filter("<think>weigh it</think>Ship on Friday.") == "Ship on Friday.")
    }

    // MARK: - An empty enhancement must never hide the transcript

    @Test func emptyEnhancementFallsBackToTheTranscript() {
        let transcription = Transcription(text: "Ship the build on Friday.", duration: 3)
        transcription.enhancedText = ""
        #expect(transcription.displayText == "Ship the build on Friday.")
        #expect(!transcription.hasEnhancement)
    }

    @Test func whitespaceOnlyEnhancementFallsBackToTheTranscript() {
        let transcription = Transcription(text: "Ship the build on Friday.", duration: 3)
        transcription.enhancedText = "\n\n   \n"
        #expect(transcription.displayText == "Ship the build on Friday.")
        #expect(!transcription.hasEnhancement)
    }

    @Test func absentEnhancementFallsBackToTheTranscript() {
        let transcription = Transcription(text: "Ship the build on Friday.", duration: 3)
        #expect(transcription.displayText == "Ship the build on Friday.")
        #expect(!transcription.hasEnhancement)
    }

    @Test func realEnhancementIsPreferredOverTheTranscript() {
        let transcription = Transcription(text: "ship the build friday", duration: 3)
        transcription.enhancedText = "Ship the build on Friday."
        #expect(transcription.displayText == "Ship the build on Friday.")
        #expect(transcription.hasEnhancement)
    }
}

/// The enhancement system prompt earns its shape from measurement, so the parts that moved the
/// numbers are pinned here. Against Gemma 4 E2B over the 20-case dictation set, three runs each:
/// the previous wording scored 9/20 and answered dictated questions (never-answers 1/3); leading
/// with the two absolute rules and showing a worked failure for each scored 13/20 and 3/3.
struct EnhancementPromptContractTests {

    private var prompt: String {
        String(format: AIPrompts.customPromptTemplate, "RULES")
    }

    @Test func theTwoAbsoluteRulesLeadThePrompt() {
        let translate = prompt.range(of: "ABSOLUTE RULE 1 — NEVER TRANSLATE")
        let answer = prompt.range(of: "ABSOLUTE RULE 2 — NEVER ANSWER")
        let rules = prompt.range(of: "RULES")
        #expect(translate != nil)
        #expect(answer != nil)
        // Both must precede the prompt-specific rules; small models follow what they read first.
        if let translate, let answer, let rules {
            #expect(translate.lowerBound < rules.lowerBound)
            #expect(answer.lowerBound < rules.lowerBound)
        }
    }

    @Test func eachAbsoluteRuleShowsAWorkedFailure() {
        // The contrast is what small instruct models actually follow, not the prohibition.
        #expect(prompt.contains("Correct output:"))
        #expect(prompt.contains("WRONG output:"))
    }

    /// 2.8.2 shipped a prompt that named Hebrew, and small models then translated *into* it.
    /// The never-translate example must therefore illustrate the rule without carrying any
    /// specific language — measured identical (13/20, mixed-script 2/2, never-answers 3/3 over
    /// three runs) with and without a real Hebrew example, so neutrality is free.
    @Test func theNeverTranslateExampleNamesNoLanguageAndUsesNoForeignScript() {
        #expect(prompt.contains("original script"))
        for named in ["hebrew", "arabic", "russian", "spanish", "french", "chinese"] {
            #expect(!prompt.localizedCaseInsensitiveContains(named), "\(named)")
        }
        let nonLatin = prompt.unicodeScalars.filter { scalar in
            EnhancementLanguageGuard.script(of: scalar).map { $0 != .latin } ?? false
        }
        #expect(nonLatin.isEmpty, "prompt carries non-Latin letters: \(String(String.UnicodeScalarView(nonLatin)))")
    }

    @Test func thePromptForbidsEchoingItsOwnTags() {
        #expect(prompt.contains("NEVER repeat the <TRANSCRIPT> tags"))
    }

    @Test func theCallerSuppliedRulesAreStillInterpolated() {
        #expect(prompt.contains("RULES"))
        #expect(!prompt.contains("%@"))
    }
}
