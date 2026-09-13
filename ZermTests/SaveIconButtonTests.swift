import Foundation
import Testing
@testable import Zerm

struct SaveIconButtonTests {

    @Test func hebrewTextKeepsItsWords() {
        #expect(SaveIconButton.suggestedFileName(for: "שלום עולם, מה נשמע?") == "שלום-עולם-מה-נשמע")
    }

    @Test func latinTextIsLowercasedAndStripped() {
        #expect(SaveIconButton.suggestedFileName(for: "  Hello, World!\nThis is Zerm 2.8 ") == "hello-world-this-is-zerm-28")
    }

    @Test func onlyTheFirstEightWordsAreUsed() {
        #expect(SaveIconButton.suggestedFileName(for: "one two three four five six seven eight nine ten")
            == "one-two-three-four-five-six-seven-eight")
    }

    @Test func longNamesAreCappedWithoutATrailingHyphen() {
        let name = SaveIconButton.suggestedFileName(for: String(repeating: "abcdefghi ", count: 8))
        #expect(name.count <= 50)
        #expect(!name.hasSuffix("-"))
    }

    @Test func textWithoutLettersFallsBack() {
        let name = SaveIconButton.suggestedFileName(for: "?! … —")
        #expect(!name.isEmpty)
        #expect(name == String(localized: "Transcription"))
    }
}
