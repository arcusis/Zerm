import Testing
@testable import Zerm

struct DictationCommandTests {

    @Test func newLineCommand() {
        let out = DictationCommandProcessor.process("hello new line world")
        #expect(out.contains("\n"))
        #expect(out.hasPrefix("hello"))
        #expect(out.contains("world"))
    }

    @Test func spokenPunctuation() {
        let out = DictationCommandProcessor.process("hello comma world period")
        #expect(out.contains(","))
        #expect(out.contains("."))
        #expect(!out.lowercased().contains("comma"))
        #expect(!out.lowercased().contains("period"))
    }

    @Test func scratchThatRemovesPriorClause() {
        let out = DictationCommandProcessor.process("keep this. drop that scratch that keep going")
        #expect(out.lowercased().contains("keep this"))
        #expect(!out.lowercased().contains("drop that"))
        #expect(out.lowercased().contains("keep going"))
    }
}
