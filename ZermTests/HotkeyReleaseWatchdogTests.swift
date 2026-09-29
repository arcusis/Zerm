import AppKit
import Testing
@testable import Zerm

@MainActor
struct HotkeyReleaseWatchdogTests {
    @Test func missedPushToTalkReleaseUsesNormalStopOnce() async {
        var now: TimeInterval = 0
        var isDown = true
        var isRecording = true
        var stopCount = 0
        let watchdog = HotkeyReleaseWatchdog(clock: { now }, sleep: { _ in
            await Task.yield()
            now += 0.05
        })

        watchdog.start(
            isKeyDown: { isDown },
            onRelease: { _ in
                stopCount += 1
                isRecording = false
            },
            shouldForceStop: { _ in isRecording },
            onForceStop: { stopCount += 1 }
        )
        isDown = false
        await settle()

        #expect(stopCount == 1)
        #expect(!watchdog.isActive)
    }

    @Test func normalKeyUpCancelsWatchdogWithoutSecondStop() async {
        var now: TimeInterval = 0
        var isDown = true
        var stopCount = 0
        let watchdog = HotkeyReleaseWatchdog(clock: { now }, sleep: { _ in
            await Task.yield()
            now += 0.05
        })
        watchdog.start(
            isKeyDown: { isDown },
            onRelease: { _ in stopCount += 1 },
            shouldForceStop: { _ in false },
            onForceStop: { stopCount += 1 }
        )

        stopCount += 1
        isDown = false
        watchdog.cancel()
        await settle()

        #expect(stopCount == 1)
    }

    @Test func toggleModeDoesNotStartWatchdog() {
        #expect(!HotkeyReleaseWatchdog.shouldWatch(mode: .toggle))
        #expect(HotkeyReleaseWatchdog.shouldWatch(mode: .pushToTalk))
        #expect(HotkeyReleaseWatchdog.shouldWatch(mode: .hybrid))
    }

    @Test func hybridTapAndHoldUseExistingThreshold() {
        #expect(!HotkeyReleaseWatchdog.isHybridPushToTalk(pressDuration: 0.49, threshold: 0.5))
        #expect(HotkeyReleaseWatchdog.isHybridPushToTalk(pressDuration: 0.5, threshold: 0.5))
    }

    @Test func modifierAndCustomKeyStateSourcesCoverFnAndSidedModifiers() {
        let downKeys: Set<CGKeyCode> = [0x3D, 0x37]
        let keyState: (CGKeyCode) -> Bool = { downKeys.contains($0) }

        #expect(HotkeyReleaseWatchdog.isDown(.modifier(.rightOption), flags: .maskAlternate, keyState: keyState))
        let rightOptionFlags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        #expect(!HotkeyReleaseWatchdog.isDown(.modifier(.leftOption), flags: rightOptionFlags, keyState: keyState))
        #expect(HotkeyReleaseWatchdog.isDown(.modifier(.rightOption), flags: rightOptionFlags, keyState: { _ in false }))
        #expect(HotkeyReleaseWatchdog.isDown(.modifier(.leftCommand), flags: .maskCommand, keyState: keyState))
        #expect(HotkeyReleaseWatchdog.isDown(.key(0x3D), flags: [], keyState: keyState))
        #expect(HotkeyReleaseWatchdog.isDown(.modifier(.fn), flags: .maskSecondaryFn, keyState: { _ in false }))
        #expect(!HotkeyReleaseWatchdog.isDown(.modifier(.fn), flags: [], keyState: { _ in true }))
    }

    @Test func hybridTapRemainsHandsFreePastFallbackDeadline() async {
        var now: TimeInterval = 0.1
        var stopCount = 0
        var releases: [TimeInterval] = []
        let watchdog = HotkeyReleaseWatchdog(clock: { now }, sleep: { _ in
            await Task.yield()
            now += 0.05
        })
        watchdog.start(
            isKeyDown: { false },
            onRelease: { releases.append($0) },
            shouldForceStop: { releasedAt in
                HotkeyReleaseWatchdog.isHybridPushToTalk(pressDuration: releasedAt, threshold: 0.5)
            },
            onForceStop: { stopCount += 1 }
        )
        await settle()
        #expect(now >= 1)
        #expect(releases.count == 1)
        #expect(stopCount == 0)
    }

    @Test func hybridHoldReleasedDuringStartupStopsAfterRecordingBecomesReady() async {
        var now: TimeInterval = 0.6
        var isRecording = false
        var stopCount = 0
        let watchdog = HotkeyReleaseWatchdog(clock: { now }, sleep: { _ in
            await Task.yield()
            now += 0.05
            if now >= 1 { isRecording = true }
        })
        watchdog.start(
            isKeyDown: { false },
            onRelease: { _ in #expect(!isRecording) },
            shouldForceStop: { releasedAt in
                isRecording && HotkeyReleaseWatchdog.isHybridPushToTalk(pressDuration: releasedAt, threshold: 0.5)
            },
            onForceStop: { stopCount += 1; isRecording = false }
        )
        await settle()
        #expect(stopCount == 1)
        #expect(!watchdog.isActive)
    }

    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }
}
