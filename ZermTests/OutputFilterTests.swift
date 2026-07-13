import Testing
@testable import Zerm

struct OutputFilterTests {

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
