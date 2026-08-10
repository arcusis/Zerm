import Combine
import Foundation

/// Compatibility shell for the retired cross-application media control preference.
///
/// macOS has no public API that can determine and pause every app's active media session.
/// Sending an unconditional Play/Pause key is unsafe because it can start previously stopped
/// media. Keep the type temporarily for settings import compatibility, but never control another
/// app. Public system muting remains Zerm's supported speaker-bleed protection.
@MainActor
final class PlaybackController: ObservableObject {
    static let shared = PlaybackController()

    @Published var isPauseMediaEnabled = false {
        didSet {
            // Reject legacy imports and stale UI bindings rather than persisting a preference
            // that cannot be implemented safely with supported APIs.
            if isPauseMediaEnabled { isPauseMediaEnabled = false }
            UserDefaults.standard.set(false, forKey: "isPauseMediaEnabled")
        }
    }

    private init() {
        UserDefaults.standard.set(false, forKey: "isPauseMediaEnabled")
    }

    func pauseMedia() async {
        // Intentionally no-op. See type documentation.
    }

    func resumeMedia() async {
        // Intentionally no-op. See type documentation.
    }
}
