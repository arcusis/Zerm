import Foundation
import Testing
@testable import Zerm

/// Double-press Escape to cancel a recording or Read Aloud (VoiceInk c35c673, 59e6265).
@MainActor
struct EscapeDoublePressTrackerTests {

    /// Holds every timer sleep until the test fires or cancels it.
    @MainActor
    final class ManualSleep {
        private var pending: [CheckedContinuation<Void, Error>] = []

        var pendingCount: Int { pending.count }

        func sleep(_ interval: TimeInterval) async throws {
            try await withCheckedThrowingContinuation { pending.append($0) }
        }

        /// Completes the oldest sleep, as if its window elapsed.
        func elapse() {
            pending.removeFirst().resume()
        }

        /// Fails the oldest sleep, as `Task.sleep` does when its task is cancelled.
        func cancel() {
            pending.removeFirst().resume(throwing: CancellationError())
        }
    }

    private let clock = ManualSleep()

    private func makeTracker() -> EscapeDoublePressTracker {
        EscapeDoublePressTracker(window: 1.5, sleep: clock.sleep)
    }

    private func waitForTimers(_ count: Int) async throws {
        for _ in 0..<100 where clock.pendingCount < count { await Task.yield() }
        try #require(clock.pendingCount == count)
    }

    /// Lets resumed timer tasks run to completion on the main actor.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func firstPressArmsAndShowsTheHint() {
        let tracker = makeTracker()
        #expect(tracker.press() == .armed(showsHint: true))
        #expect(tracker.isArmed)
    }

    @Test func secondPressInsideTheWindowConfirms() {
        let tracker = makeTracker()
        _ = tracker.press()
        #expect(tracker.press() == .confirmed)
        #expect(!tracker.isArmed)
    }

    @Test func timerExpiryDisarms() async throws {
        let tracker = makeTracker()
        _ = tracker.press()
        try await waitForTimers(1)

        clock.elapse()
        await settle()

        #expect(!tracker.isArmed)
        #expect(tracker.press() == .armed(showsHint: false))
    }

    @Test func hintIsShownOncePerSession() async throws {
        let tracker = makeTracker()
        #expect(tracker.press() == .armed(showsHint: true))
        try await waitForTimers(1)
        clock.elapse()
        await settle()

        #expect(tracker.press() == .armed(showsHint: false))
        #expect(tracker.press() == .confirmed)
        #expect(tracker.press() == .armed(showsHint: false))

        tracker.reset()
        #expect(tracker.press() == .armed(showsHint: true))
    }

    @Test func cancelledTimerDoesNotResetState() async throws {
        let tracker = makeTracker()
        _ = tracker.press()
        try await waitForTimers(1)

        // The recorder is dismissed, then a new session arms again before the old timer unwinds.
        tracker.reset()
        _ = tracker.press()
        try await waitForTimers(2)

        clock.cancel()
        await settle()
        #expect(tracker.isArmed)
        #expect(tracker.press() == .confirmed)
    }

    @Test func staleTimerThatStillCompletesDoesNotResetState() async throws {
        let tracker = makeTracker()
        _ = tracker.press()
        try await waitForTimers(1)

        // Confirm, then arm again: the first press's timer finishing late must not disarm the new press.
        #expect(tracker.press() == .confirmed)
        _ = tracker.press()
        try await waitForTimers(2)

        clock.elapse()
        await settle()
        #expect(tracker.isArmed)
        #expect(tracker.press() == .confirmed)
    }
}
