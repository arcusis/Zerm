import Testing
@testable import Zerm

struct WhisperTextFormatterTests {

    @Test func formatIsIdempotentOnSimpleText() {
        let input = "Hello world."
        let once = WhisperTextFormatter.format(input)
        let twice = WhisperTextFormatter.format(once)
        #expect(once == twice)
    }
}
