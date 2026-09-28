import CoreGraphics
import Testing
@testable import Zerm

/// The latency fixes from #354 must not change behavior.
struct LatencyPathTests {

    @Test func pasteWaitsOnlyWhileAModifierIsHeld() {
        #expect(!CursorPaster.hasModifierHeld([]))
        #expect(!CursorPaster.hasModifierHeld(.maskAlphaShift), "Caps Lock is a state, not a held key")
        for flag: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn] {
            #expect(CursorPaster.hasModifierHeld(flag))
        }
    }

    /// The presence cache must follow saves and deletes, or a new key would not make its models
    /// usable until relaunch.
    @Test func apiKeyPresenceFollowsSavesAndDeletes() throws {
        let manager = APIKeyManager.shared
        let provider = "gladia"
        // Never touch a key the dev build already has.
        try #require(manager.getAPIKey(forProvider: provider) == nil)

        #expect(!manager.hasAPIKey(forProvider: provider))
        manager.saveAPIKey("test-key", forProvider: provider)
        #expect(manager.hasAPIKey(forProvider: provider))
        manager.deleteAPIKey(forProvider: provider)
        #expect(!manager.hasAPIKey(forProvider: provider))
    }
}
