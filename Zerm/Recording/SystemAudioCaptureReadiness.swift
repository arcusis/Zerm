import AppKit
import AVFoundation
import Combine
import Foundation

/// End-to-end readiness for Core Audio process taps.
///
/// macOS doesn't expose an authorization-status API for system-audio taps. Apple requests the
/// permission when an aggregate device containing a tap starts, and a denied tap can still run
/// while returning only zeroes. A truthful check therefore sends known audio through the same
/// tap, aggregate device, and converter path used by Meetings and verifies that samples return.
@MainActor
final class SystemAudioCaptureReadiness: ObservableObject {
    static let shared = SystemAudioCaptureReadiness()

    enum Status: Equatable {
        case notTested
        case testing
        case verified(Date)
        case failed(String)
    }

    enum ProbeResult: Equatable {
        case verified
        case failed(String)
    }

    @Published private(set) var status: Status

    private static let verifiedAtKey = "systemAudioCaptureVerifiedAt"
    private static let verificationTokenKey = "systemAudioCaptureVerificationToken"

    private let defaults: UserDefaults
    private let verificationToken: String
    private let isMeetingActive: @MainActor () -> Bool
    private let probe: @MainActor () async -> ProbeResult
    private var probeTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        verificationToken: String? = nil,
        isMeetingActive: @escaping @MainActor () -> Bool = {
            MeetingActivityMonitor.shared.isActive
        },
        probe: @escaping @MainActor () async -> ProbeResult = SystemAudioCaptureProbe.run
    ) {
        self.defaults = defaults
        self.verificationToken = verificationToken ?? Self.currentVerificationToken
        self.isMeetingActive = isMeetingActive
        self.probe = probe

        if defaults.string(forKey: Self.verificationTokenKey) == self.verificationToken,
           let date = defaults.object(forKey: Self.verifiedAtKey) as? Date {
            status = .verified(date)
        } else {
            status = .notTested
        }
    }

    deinit {
        probeTask?.cancel()
    }

    func test() {
        guard probeTask == nil else { return }
        guard !isMeetingActive() else {
            status = .failed(String(localized: "Stop the active meeting before testing system audio."))
            return
        }

        status = .testing
        probeTask = Task { [weak self] in
            guard let self else { return }
            let result = await probe()
            guard !Task.isCancelled else { return }

            switch result {
            case .verified:
                let date = Date()
                defaults.set(date, forKey: Self.verifiedAtKey)
                defaults.set(verificationToken, forKey: Self.verificationTokenKey)
                status = .verified(date)
            case .failed(let message):
                defaults.removeObject(forKey: Self.verifiedAtKey)
                defaults.removeObject(forKey: Self.verificationTokenKey)
                status = .failed(message)
            }
            probeTask = nil
        }
    }

    func invalidate() {
        defaults.removeObject(forKey: Self.verifiedAtKey)
        defaults.removeObject(forKey: Self.verificationTokenKey)
        status = .notTested
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    static var currentVerificationToken: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(build)-\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

@MainActor
enum SystemAudioCaptureProbe {
    private static let toneDuration: TimeInterval = 0.35

    static func run() async -> SystemAudioCaptureReadiness.ProbeResult {
        guard #available(macOS 14.2, *) else {
            return .failed(String(localized: "System audio capture requires macOS 14.2 or later."))
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-system-audio-test-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let writer = SystemAudioTrackWriter()
        let tap = SystemAudioTap()
        let tone = ProbeTone()

        defer {
            tone.stop()
            tap.stop()
            writer.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
            try writer.open(at: temporaryURL)
            tap.captureScope = .allSystemAudio
            // Normal meetings exclude Zerm. This explicit test includes it so a known signal can
            // prove that TCC, the process tap, the aggregate, and conversion all work together.
            tap.excludesOwnProcess = false
            tap.realtimeSink = writer
            try tap.start()

            try await Task.sleep(for: .milliseconds(250))
            try tone.play(duration: toneDuration)
            try await Task.sleep(for: .milliseconds(650))

            if writer.hasCapturedSignal {
                return .verified
            }
            return .failed(String(localized: "The test sound played, but no system audio returned to Zerm. Confirm Zerm under Screen & System Audio Recording, fully quit and reopen Zerm, then test again."))
        } catch is CancellationError {
            return .failed(String(localized: "The system audio test was cancelled."))
        } catch {
            let format = String(localized: "System audio could not start: %@")
            return .failed(String.localizedStringWithFormat(format, error.localizedDescription))
        }
    }

    private final class ProbeTone {
        private let engine = AVAudioEngine()
        private let player = AVAudioPlayerNode()

        func play(duration: TimeInterval) throws {
            let sampleRate = 48_000.0
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw ProbeError.toneUnavailable
            }
            let frameCount = AVAudioFrameCount(sampleRate * duration)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                  let samples = buffer.floatChannelData?[0] else {
                throw ProbeError.toneUnavailable
            }

            buffer.frameLength = frameCount
            for frame in 0..<Int(frameCount) {
                let progress = Double(frame) / Double(max(1, Int(frameCount) - 1))
                let envelope = min(1, min(progress, 1 - progress) / 0.08)
                samples[frame] = Float(
                    sin(2 * Double.pi * 660 * Double(frame) / sampleRate) * 0.06 * envelope
                )
            }

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: [])
            player.play()
        }

        func stop() {
            player.stop()
            engine.stop()
        }
    }

    private enum ProbeError: LocalizedError {
        case toneUnavailable

        var errorDescription: String? {
            String(localized: "Zerm could not create the system audio test sound.")
        }
    }
}
