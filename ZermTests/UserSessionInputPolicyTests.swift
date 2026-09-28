import CoreGraphics
import Testing
@testable import Zerm

/// Global shortcuts must not start dictation on a locked or switched-away session (#352).
struct UserSessionInputPolicyTests {

    private let unlocked: [String: Any] = [
        kCGSessionOnConsoleKey as String: true,
        kCGSessionLoginDoneKey as String: true
    ]

    @Test func anUnlockedConsoleSessionAllowsShortcuts() {
        #expect(UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: unlocked))
    }

    @Test func aLockedScreenBlocksShortcuts() {
        var locked = unlocked
        locked["CGSSessionScreenIsLocked"] = true
        #expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: locked))
    }

    @Test func aSessionOffTheConsoleOrMidLoginBlocksShortcuts() {
        var switchedAway = unlocked
        switchedAway[kCGSessionOnConsoleKey as String] = false
        #expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: switchedAway))

        var loggingIn = unlocked
        loggingIn[kCGSessionLoginDoneKey as String] = NSNumber(value: false)
        #expect(!UserSessionInputPolicy.allowsShortcutHandling(sessionProperties: loggingIn))
    }
}
