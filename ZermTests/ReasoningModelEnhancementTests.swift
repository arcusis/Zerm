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

    /// The Qwen3 family is off the catalogue, so nothing shipped sets this today. The flag and
    /// the bridge's reasoning-skip must keep working regardless: a future catalogue entry, or a
    /// user's own Ollama/Local-CLI model, can still open a `<think>` block.
    @Test func thinkingSuppressionIsScopedToTheQwen3Family() {
        for package in LocalLLMModelManager.packages {
            let expected = package.fileName.lowercased().hasPrefix("qwen3")
            #expect(package.disablesThinking == expected, "\(package.fileName)")
        }
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
