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

/// The start cue waits for real audio, but never longer than its timeout (first-audio gating).
@MainActor
struct FirstAudioWaitTests {
    @Test func waitingWithoutAudioEndsAtTheTimeout() async {
        let recorder = Recorder()
        let start = ProcessInfo.processInfo.systemUptime
        let arrived = await recorder.waitForFirstAudio(timeout: 0.05)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        #expect(!arrived)
        // Only that it gave up: a loaded CI runner schedules the timeout late (see #346).
        #expect(elapsed >= 0.05 && elapsed < 30)
    }

    @Test func aSecondWaitReplacesTheFirstWithoutHanging() async {
        let recorder = Recorder()
        async let first = recorder.waitForFirstAudio(timeout: 5)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = await recorder.waitForFirstAudio(timeout: 0.05)
        #expect(await first == false)
        #expect(!second)
    }
}
