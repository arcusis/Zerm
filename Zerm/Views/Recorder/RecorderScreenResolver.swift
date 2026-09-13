import AppKit

/// Resolves the screen the recorder panel should be placed on.
///
/// `NSScreen.main` is the screen holding the key window. Zerm usually has no key window, so it
/// can be `nil` — most plausibly while displays are asleep or being reconfigured. Falling back
/// to a rect at the global origin put a transparent, shadowless panel behind the Dock, which
/// looks exactly like a panel that never appeared, so callers skip showing instead.
enum RecorderScreenResolver {
    static func resolve() -> NSScreen? {
        if let main = NSScreen.main { return main }

        let mouseLocation = NSEvent.mouseLocation
        if let screenUnderMouse = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screenUnderMouse
        }

        return NSScreen.screens.first
    }
}
