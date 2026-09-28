import Foundation
import os

/// Measures the two latencies a user feels: from trigger to recording, and from stop to the
/// text landing at the cursor. Each is a Points of Interest interval for Instruments and one
/// line in the debug log, so real dictations produce numbers without a profiler attached.
@MainActor
final class DictationLatency {
    static let shared = DictationLatency()
    static let signposter = OSSignposter(subsystem: "com.arcusis.zerm", category: .pointsOfInterest)

    private var startInterval: (state: OSSignpostIntervalState, uptime: TimeInterval)?
    private var stopInterval: (state: OSSignpostIntervalState, uptime: TimeInterval)?

    private init() {}

    /// Follows the engine's lifecycle; called for every state change.
    func record(_ state: RecordingState) {
        let now = ProcessInfo.processInfo.systemUptime
        switch state {
        case .starting:
            startInterval = (Self.signposter.beginInterval("Start"), now)
        case .recording:
            guard let startInterval else { return }
            Self.signposter.endInterval("Start", startInterval.state)
            DebugLogger.shared.log("Latency", "trigger→recording \(Self.milliseconds(since: startInterval.uptime, now: now)) ms")
            self.startInterval = nil
        case .transcribing where stopInterval == nil:
            stopInterval = (Self.signposter.beginInterval("Stop"), now)
        case .idle:
            // A dictation that ended without a paste (cancelled, empty, failed).
            if let startInterval { Self.signposter.endInterval("Start", startInterval.state) }
            if let stopInterval { Self.signposter.endInterval("Stop", stopInterval.state) }
            startInterval = nil
            stopInterval = nil
        default:
            break
        }
    }

    /// The paste command was posted; the stop interval ends here.
    func recordPaste() {
        guard let stopInterval else { return }
        let now = ProcessInfo.processInfo.systemUptime
        Self.signposter.endInterval("Stop", stopInterval.state)
        DebugLogger.shared.log("Latency", "stop→paste \(Self.milliseconds(since: stopInterval.uptime, now: now)) ms")
        self.stopInterval = nil
    }

    private static func milliseconds(since start: TimeInterval, now: TimeInterval) -> Int {
        Int(((now - start) * 1000).rounded())
    }
}
