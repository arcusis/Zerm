import Foundation

/// Offscreen PNG renders are review artifacts, not correctness checks: they depend on the
/// runner's window server and are flaky on CI. Run them with
/// `TEST_RUNNER_ZERM_RENDER_SNAPSHOTS=1 make test` (xcodebuild forwards TEST_RUNNER_ variables).
enum RenderSnapshots {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ZERM_RENDER_SNAPSHOTS"] == "1"
    }
}
