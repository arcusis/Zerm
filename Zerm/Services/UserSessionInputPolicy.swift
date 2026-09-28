import CoreGraphics
import Foundation

/// Whether the current macOS user session may act on global shortcuts. A locked screen, a
/// session switched away from the console, or an unfinished login must not start dictation.
enum UserSessionInputPolicy {
    // CGSession has no public constant for this long-standing WindowServer property.
    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    static var allowsShortcutHandling: Bool {
        guard let properties = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return allowsShortcutHandling(sessionProperties: properties)
    }

    static func allowsShortcutHandling(sessionProperties: [String: Any]) -> Bool {
        guard booleanValue(sessionProperties[kCGSessionOnConsoleKey as String]) == true,
              booleanValue(sessionProperties[kCGSessionLoginDoneKey as String]) == true else {
            return false
        }
        return booleanValue(sessionProperties[screenIsLockedKey]) != true
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }
}
