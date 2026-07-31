import Foundation
import AppKit
import OSLog

/// Whether Zerm is allowed to record what the Mac is playing.
///
/// System audio capture is gated by the `kTCCServiceAudioCapture` privacy service, and Apple
/// ships no public API to read or request it. An unauthorised process tap does not fail — every
/// Core Audio call returns `noErr`, the IOProc fires at the correct rate, and every sample is
/// silence — so without this the only symptom is an empty recording.
///
/// The status comes from the private TCC framework, loaded dynamically. That is deliberate: if
/// Apple ever moves or removes these symbols the lookup simply fails and everything degrades to
/// `.unknown`, where the caller falls back to `MeetingRecordingSession.systemAudioSilent` — the
/// empirical "we have been recording for a while and heard nothing" signal. Nothing here can
/// crash the app, and nothing depends on the private call succeeding.
///
/// Approach adapted from insidegui/AudioCap (BSD-2-Clause), where it is likewise gated as
/// experimental.
///
/// - Important: `status()` is **not** yet trusted as the source of truth, and no UI branches on
///   it. Probing it from a test binary returned `.authorized` for audio capture on a machine
///   whose TCC database did not grant that service, and where an actual tap recorded pure
///   silence — so preflight appears to answer for a different identity than the one Core Audio
///   enforces against. Until that is resolved against the signed app,
///   `MeetingRecordingSession.systemAudioSilent` remains the reliable signal, and this exists to
///   be validated and to drive the request prompt.
enum SystemAudioPermission {

    enum Status: Equatable {
        case authorized
        case denied
        /// The private lookup was unavailable, so nothing can be asserted either way.
        case unknown
    }

    private static let logger = Logger(subsystem: "com.arcusis.zerm", category: "SystemAudioPermission")
    private static let service = "kTCCServiceAudioCapture" as CFString

    // MARK: - Status

    static func status() -> Status {
        guard let preflight = Symbols.shared.preflight else { return .unknown }
        // 0 = authorized, 1 = denied, 2 = unknown/undetermined.
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    // MARK: - Request

    /// Presents the system prompt, if it has not already been answered.
    ///
    /// Returns `false` when the request could not be made at all, which the caller should treat
    /// as "unknown", not as a denial — sending the user to Settings is still the right move.
    @discardableResult
    static func request() async -> Bool {
        guard let request = Symbols.shared.request else {
            logger.notice("TCC request unavailable; falling back to Settings")
            return false
        }
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private framework

    private final class Symbols {
        static let shared = Symbols()

        typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
        typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

        let preflight: PreflightFunc?
        let request: RequestFunc?

        private init() {
            let path = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
            guard let handle = dlopen(path, RTLD_NOW) else {
                SystemAudioPermission.logger.notice("TCC framework unavailable: \(String(cString: dlerror()), privacy: .public)")
                preflight = nil
                request = nil
                return
            }
            preflight = dlsym(handle, "TCCAccessPreflight").map {
                unsafeBitCast($0, to: PreflightFunc.self)
            }
            request = dlsym(handle, "TCCAccessRequest").map {
                unsafeBitCast($0, to: RequestFunc.self)
            }
            if preflight == nil || request == nil {
                SystemAudioPermission.logger.notice("TCC symbols missing; system audio status will read as unknown")
            }
        }
    }
}
