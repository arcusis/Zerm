import Testing
import Foundation
@testable import Zerm

struct RefineInPlaceTests {

    // MARK: - Range arithmetic

    @Test func insertionStartsWhereTheSelectionWas() {
        let selection = CFRange(location: 12, length: 0)
        let result = AXTextAnchorCapture.expectedInsertion(afterSelection: selection, pastedText: "hello there")
        #expect(result?.range.location == 12)
        #expect(result?.range.length == 11)
        #expect(result?.caret == 23)
    }

    /// Pasting over a selection still begins at the selection's start, not its end.
    @Test func insertionOverASelectionStartsAtItsOrigin() {
        let selection = CFRange(location: 5, length: 9)
        let result = AXTextAnchorCapture.expectedInsertion(afterSelection: selection, pastedText: "abc")
        #expect(result?.range.location == 5)
        #expect(result?.caret == 8)
    }

    /// The whole reason lengths are measured in UTF-16: an emoji is one Character but two
    /// code units, and a flag is four. Measuring with `count` would leave the replacement
    /// range short and overwrite the wrong span of the user's text.
    @Test func lengthsAreMeasuredInUTF16CodeUnits() {
        let text = "ok 👍"
        #expect(text.count == 4)
        let result = AXTextAnchorCapture.expectedInsertion(
            afterSelection: CFRange(location: 0, length: 0),
            pastedText: text
        )
        #expect(result?.range.length == 5)

        let flag = "🇬🇧"
        #expect(flag.count == 1)
        let flagResult = AXTextAnchorCapture.expectedInsertion(
            afterSelection: CFRange(location: 0, length: 0),
            pastedText: flag
        )
        #expect(flagResult?.range.length == 4)
    }

    @Test func combiningMarksCountEveryScalar() {
        let text = "e\u{0301}"
        #expect(text.count == 1)
        let result = AXTextAnchorCapture.expectedInsertion(
            afterSelection: CFRange(location: 0, length: 0),
            pastedText: text
        )
        #expect(result?.range.length == 2)
    }

    @Test func emptyPasteHasNoAnchor() {
        #expect(AXTextAnchorCapture.expectedInsertion(
            afterSelection: CFRange(location: 0, length: 0),
            pastedText: ""
        ) == nil)
    }

    // MARK: - Output mode

    @Test func onlyInstantSkipsEnhancement() {
        #expect(DictationOutputMode.instant.usesEnhancement == false)
        #expect(DictationOutputMode.instantRefine.usesEnhancement)
        #expect(DictationOutputMode.enhanced.usesEnhancement)
    }

    @Test func onlyEnhancedWaitsBeforePasting() {
        #expect(DictationOutputMode.instant.pastesImmediately)
        #expect(DictationOutputMode.instantRefine.pastesImmediately)
        #expect(DictationOutputMode.enhanced.pastesImmediately == false)
    }

    // MARK: - Token budget

    @Test @MainActor func tokenBudgetScalesWithInputAndStaysBounded() {
        #expect(AIEnhancementService.tokenBudget(forInput: "hi") == 64)
        #expect(AIEnhancementService.tokenBudget(forInput: String(repeating: "a", count: 10_000)) == 512)

        let medium = String(repeating: "a", count: 600)
        let budget = AIEnhancementService.tokenBudget(forInput: medium)
        #expect(budget > 64 && budget < 512)
    }

    // MARK: - Power Mode enhancement override

    /// An explicit `true` was a deliberate choice and must survive. A `false` was almost
    /// always just the seeded default, and treating it as an instruction to suppress
    /// enhancement is what made the global toggle look broken.
    @Test func legacyConfigsMigrateOffToInherit() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"General","emoji":"💼",
         "isAIEnhancementEnabled":false,"useScreenCapture":false}
        """
        let config = try JSONDecoder().decode(PowerModeConfig.self, from: Data(legacy.utf8))
        #expect(config.enhancementOverride == .inherit)
    }

    @Test func legacyConfigsMigrateOnToOn() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Email","emoji":"✉️",
         "isAIEnhancementEnabled":true,"useScreenCapture":false}
        """
        let config = try JSONDecoder().decode(PowerModeConfig.self, from: Data(legacy.utf8))
        #expect(config.enhancementOverride == .on)
    }

    @Test func explicitOverrideSurvivesARoundTrip() throws {
        let config = PowerModeConfig(
            name: "Terminal",
            emoji: "⌨️",
            isAIEnhancementEnabled: false,
            enhancementOverride: .off
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PowerModeConfig.self, from: data)
        #expect(decoded.enhancementOverride == .off)
    }
}
