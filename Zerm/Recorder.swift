import Foundation
import AVFoundation
import CoreAudio
import os

@MainActor
class Recorder: NSObject, ObservableObject {
    private var recorder: CoreAudioRecorder?
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "Recorder")
    private let deviceManager = AudioDeviceManager.shared
    private var deviceSwitchObserver: NSObjectProtocol?
    private var isReconfiguring = false
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    @Published var audioMeter = AudioMeter(averagePower: 0, peakPower: 0)
    private var audioMeterUpdateTimer: DispatchSourceTimer?
    private let audioMeterQueue = DispatchQueue(label: "com.arcusis.zerm.audiometer", qos: .userInteractive)
    /// Dedicated serial queue for hardware setup.
    private let audioSetupQueue = DispatchQueue(label: "com.arcusis.zerm.audioSetup", qos: .userInitiated)
    private var audioRestorationTask: Task<Void, Never>?
    private let meterSmoother = AudioMeterSmoother()
    /// Whether this recording has delivered non-silent audio yet, and who is waiting for it.
    private var hasFirstAudio = false
    private var firstAudioWaiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { recorder?.onAudioChunk = onAudioChunk }
    }
    
    enum RecorderError: Error {
        case couldNotStartRecording
    }

    /// True while the underlying audio unit is live. Goes false once the hardware
    /// recorder is stopped/disposed.
    var isHardwareRecording: Bool { recorder?.isCurrentlyRecording ?? false }

    /// Seconds since the last audio input callback, or `nil` if not recording or
    /// none received yet. Used to detect a silently-dropped capture.
    var secondsSinceLastAudioInput: Double? { recorder?.secondsSinceLastInput }
    
    override init() {
        super.init()
        setupDeviceSwitchObserver()
    }

    private func setupDeviceSwitchObserver() {
        deviceSwitchObserver = NotificationCenter.default.addObserver(
            forName: .audioDeviceSwitchRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task {
                await self?.handleDeviceSwitchRequired(notification)
            }
        }
    }

    private func handleDeviceSwitchRequired(_ notification: Notification) async {
        guard !isReconfiguring else { return }
        guard let recorder = recorder else { return }
        guard let userInfo = notification.userInfo,
              let newDeviceID = userInfo["newDeviceID"] as? AudioDeviceID else {
            logger.error("Device switch notification missing newDeviceID")
            return
        }

        // Prevent concurrent device switches and handleDeviceChange() interference
        isReconfiguring = true
        defer { isReconfiguring = false }

        logger.notice("🎙️ Device switch required: switching to device \(newDeviceID, privacy: .public)")

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try recorder.switchDevice(to: newDeviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Notify user about the switch
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == newDeviceID })?.name {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Switched to: \(deviceName)"),
                        type: .info
                    )
                }
            }

            logger.notice("🎙️ Successfully switched recording to device \(newDeviceID, privacy: .public)")
        } catch {
            logger.error("❌ Failed to switch device: \(error.localizedDescription, privacy: .public)")
            DebugLogger.shared.log("Recorder", "device switch to \(newDeviceID) FAILED: \(error.localizedDescription)")

            // If switch fails, stop recording and notify user
            await handleRecordingError(error)
        }
    }

    func startRecording(toOutputFile url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let currentDeviceID = deviceManager.getCurrentDevice()
        logger.notice("startRecording called – deviceID=\(currentDeviceID, privacy: .public), file=\(url.lastPathComponent, privacy: .public)")
        deviceManager.isRecordingActive = true

        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
        if String(currentDeviceID) != lastDeviceID {
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name {
                NotificationManager.shared.showNotification(title: String(localized: "Using: \(deviceName)"), type: .info)
            }
        }
        UserDefaults.standard.set(String(currentDeviceID), forKey: "lastUsedMicrophoneDeviceID")

        let resolvedName = deviceManager.availableDevices.first(where: { $0.id == currentDeviceID })?.name ?? "unknown"
        DebugLogger.shared.log("Recorder", "start requested: device=\(currentDeviceID) (\(resolvedName)) mode=\(deviceManager.inputMode.rawValue) file=\(url.lastPathComponent)")
        if currentDeviceID == 0 {
            DebugLogger.shared.log("Recorder", "no input device resolved (deviceID=0, mode=\(deviceManager.inputMode.rawValue))")
        }

        let deviceID = currentDeviceID

        let coreAudioRecorder = CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        hasFirstAudio = false
        coreAudioRecorder.onFirstAudio = { [weak self, weak coreAudioRecorder] in
            Task { @MainActor [weak self] in
                guard let self, let coreAudioRecorder, self.recorder === coreAudioRecorder else { return }
                self.resolveFirstAudio(true)
            }
        }
        recorder = coreAudioRecorder

        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        audioMeterUpdateTimer?.cancel()

        let capturedLogger = logger
        // Offload initialization to background thread to avoid hotkey lag.
        audioSetupQueue.async { [weak self] in
            do {
                try coreAudioRecorder.startRecording(toOutputFile: url, deviceID: deviceID)
                capturedLogger.notice("startRecording: CoreAudioRecorder started successfully")
                DispatchQueue.main.async { [weak self] in
                    self?.startAudioMeterTimer()
                }
                Task { [weak self] in
                    guard let self = self else { return }
                    await self.playbackController.pauseMedia()
                }
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                capturedLogger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
                DebugLogger.shared.log("Recorder", "start FAILED: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.stopRecording()
                    self?.deviceManager.isRecordingActive = false
                    completion(.failure(error))
                }
            }
        }
    }

    func stopRecording() {
        Task { await stopRecordingAndWaitUntilFinalized() }
    }

    /// Stops capture and waits until ExtAudioFile has been disposed. Transcribe
    /// must not open the WAV until this returns — a long take is still flushing
    /// on `audioSetupQueue`, and reading it early is how History got
    /// "The operation could not be completed" with a missing file.
    func stopRecordingAndWaitUntilFinalized() async {
        logger.notice("stopRecording called")
        audioMeterUpdateTimer?.cancel()
        audioMeterUpdateTimer = nil

        let currentRecorder = self.recorder
        recorder = nil
        onAudioChunk = nil
        resolveFirstAudio(false, waiterOnly: true)

        meterSmoother.reset()

        audioMeter = AudioMeter(averagePower: 0, peakPower: 0)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume()
            }
        }

        audioRestorationTask = Task {
            await mediaController.unmuteSystemAudio()
            await playbackController.resumeMedia()
        }
        deviceManager.isRecordingActive = false
    }

    /// Returns true once the recording delivers non-silent audio, false after `timeout` without
    /// any. The audio unit runs within ~80 ms, but a Bluetooth headset's microphone sends digital
    /// silence for 0.6–0.9 s while its call link comes up; words spoken then are lost.
    func waitForFirstAudio(timeout: TimeInterval) async -> Bool {
        if hasFirstAudio { return true }
        firstAudioWaiter?.continuation.resume(returning: false)
        let id = UUID()
        return await withCheckedContinuation { continuation in
            firstAudioWaiter = (id, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.firstAudioWaiter?.id == id else { return }
                self.resolveFirstAudio(false, waiterOnly: true)
            }
        }
    }

    private func resolveFirstAudio(_ arrived: Bool, waiterOnly: Bool = false) {
        if !waiterOnly { hasFirstAudio = true }
        firstAudioWaiter?.continuation.resume(returning: arrived)
        firstAudioWaiter = nil
    }

    private func handleRecordingError(_ error: Error) async {
        logger.error("❌ Recording error occurred: \(error.localizedDescription, privacy: .public)")

        await stopRecordingAndWaitUntilFinalized()

        // Notify the user about the recording failure
        await MainActor.run {
            NotificationManager.shared.showNotification(
                title: String(localized: "Recording Failed: \(error.localizedDescription)"),
                type: .error
            )
        }
    }

    /// Samples the live recorder on `audioMeterQueue`. The handler is handed the recorder it
    /// samples, so it never reads this main-actor object's state from that queue: stopping a
    /// recording clears `recorder` on the main actor while the timer may still be firing.
    private func startAudioMeterTimer() {
        guard let recorder else { return }
        let smoother = meterSmoother
        let timer = DispatchSource.makeTimerSource(queue: audioMeterQueue)
        // 30 Hz is smooth for the visualizer at roughly half the wakeup cost of the
        // previous 17 ms cadence — this runs for the whole recording.
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        var tickCount = 0 // only touched on audioMeterQueue (serial)
        timer.setEventHandler { [weak self, weak recorder] in
            guard let recorder else { return }
            // ~1 Hz capture-health heartbeat while debug logging is on (33 ms ticks)
            tickCount += 1
            if tickCount % 30 == 0 {
                DebugLogger.shared.log("Recorder", "heartbeat: \(recorder.debugSessionStats())")
            }
            let meter = smoother.update(averagePower: recorder.averagePower, peakPower: recorder.peakPower)
            // Dispatch to main queue for UI updates (more efficient than Task)
            DispatchQueue.main.async { [weak self] in
                self?.audioMeter = meter
            }
        }
        timer.resume()
        audioMeterUpdateTimer = timer
    }

    // MARK: - Cleanup

    deinit {
        audioMeterUpdateTimer?.cancel()
        audioRestorationTask?.cancel()
        if let observer = deviceSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
/// Normalizes and smooths recorder levels for the visualizer. Written from the meter queue and
/// reset from the main actor, so every access holds the lock.
private final class AudioMeterSmoother: @unchecked Sendable {
    private let lock = NSLock()
    private var average: Float = 0
    private var peak: Float = 0

    func reset() {
        lock.withLock {
            average = 0
            peak = 0
        }
    }

    /// Maps -60…0 dB to 0…1 and applies an exponential moving average.
    func update(averagePower: Float, peakPower: Float) -> AudioMeter {
        func normalized(_ db: Float) -> Float {
            let minVisibleDb: Float = -60.0
            let maxVisibleDb: Float = 0.0
            if db < minVisibleDb { return 0 }
            if db >= maxVisibleDb { return 1 }
            return (db - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }
        return lock.withLock {
            average = average * 0.6 + normalized(averagePower) * 0.4
            peak = peak * 0.6 + normalized(peakPower) * 0.4
            return AudioMeter(averagePower: Double(average), peakPower: Double(peak))
        }
    }
}
