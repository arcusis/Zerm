import AudioToolbox
import Foundation

/// Hardware boundary for meeting capture. Tests inject a deterministic backend and exercise the
/// real coordinator without a microphone, audio permission, or a running call application.
protocol MeetingCaptureBackend: AnyObject {
    var onChunk: ((MeetingCaptureDelivery) -> Void)? { get set }
    var onFailure: ((MeetingAudioSource, Error) -> Void)? { get set }
    var onInterruption: ((MeetingAudioSource, Error) -> Void)? { get set }
    var onDroppedFrames: ((MeetingCaptureDiscontinuity) -> Void)? { get set }
    var onStateChange: ((MeetingAudioSource, MeetingSourceHealth.Status, String?) -> Void)? { get set }

    var microphoneLevelDb: Float { get }
    var microphoneCaptureIsActive: Bool { get }
    var systemAudioLevelDb: Float { get }
    var systemAudioHasSignal: Bool { get }
    var microphoneSecondsSinceLastDelivery: TimeInterval? { get }
    var systemAudioSecondsSinceLastDelivery: TimeInterval? { get }
    var systemAudioSecondsSinceLastSignal: TimeInterval? { get }

    @MainActor func startMicrophone(writingTo url: URL) throws
    func startSystemAudio(writingTo url: URL, target: MeetingCaptureTarget) throws
    @discardableResult
    func switchMicrophone(
        to deviceID: AudioDeviceID,
        beforeRestart: () -> Void
    ) throws -> Bool
    func stopMicrophone()
    func stopSystemAudio()
}

extension MeetingCaptureBackend {
    var onInterruption: ((MeetingAudioSource, Error) -> Void)? {
        get { nil }
        set {}
    }
    var microphoneSecondsSinceLastDelivery: TimeInterval? { nil }
    var systemAudioSecondsSinceLastDelivery: TimeInterval? { nil }
    var systemAudioSecondsSinceLastSignal: TimeInterval? { nil }
}

/// Production Core Audio implementation. All device-specific behavior is confined here so the
/// session state machine and recovery logic can be tested independently.
final class CoreAudioMeetingCaptureBackend: MeetingCaptureBackend, @unchecked Sendable {
    var onChunk: ((MeetingCaptureDelivery) -> Void)?
    var onFailure: ((MeetingAudioSource, Error) -> Void)?
    var onInterruption: ((MeetingAudioSource, Error) -> Void)?
    var onDroppedFrames: ((MeetingCaptureDiscontinuity) -> Void)?
    var onStateChange: ((MeetingAudioSource, MeetingSourceHealth.Status, String?) -> Void)?

    private let microphone = CoreAudioRecorder()
    private let systemWriter = SystemAudioTrackWriter()
    private var systemTapStorage: AnyObject?

    var microphoneLevelDb: Float { microphone.averagePower }
    var microphoneCaptureIsActive: Bool { microphone.isCurrentlyRecording }
    var systemAudioLevelDb: Float { systemWriter.averagePowerDb }
    var systemAudioHasSignal: Bool { systemWriter.hasCapturedSignal }
    var microphoneSecondsSinceLastDelivery: TimeInterval? { microphone.secondsSinceLastInput }
    var systemAudioSecondsSinceLastDelivery: TimeInterval? { systemWriter.secondsSinceLastDelivery }
    var systemAudioSecondsSinceLastSignal: TimeInterval? { systemWriter.secondsSinceLastSignal }

    @available(macOS 14.2, *)
    private var systemTap: SystemAudioTap? {
        get { systemTapStorage as? SystemAudioTap }
        set { systemTapStorage = newValue }
    }

    @MainActor
    func startMicrophone(writingTo url: URL) throws {
        let deviceID = AudioDeviceManager.shared.getCurrentDevice()
        guard deviceID != 0 else { throw MeetingRecordingSession.SessionError.noMicrophoneDevice }
        // Snapshot this capture generation's callbacks. Looking up `self.onChunk` later would let
        // an old writer drain into the callback installed for a subsequent meeting.
        let chunkHandler = onChunk
        let failureHandler = onFailure
        let dropHandler = onDroppedFrames
        microphone.onTimestampedAudioChunk = { chunk in
            chunkHandler?(.init(
                source: .microphone,
                data: chunk.data,
                hostTimeNanos: Self.hostTimeNanos(from: chunk.timeStamp),
                sampleTime: Self.sampleTime(from: chunk.timeStamp),
                sourceSampleRate: chunk.sampleRate,
                frameCount: chunk.frameCount
            ))
        }
        microphone.onDroppedInputFrames = { frames, hostTimeNanos, sampleTime, sourceSampleRate in
            dropHandler?(.init(
                source: .microphone,
                droppedFrames: frames,
                hostTimeNanos: hostTimeNanos,
                sourceSampleTime: sampleTime,
                sourceSampleRate: sourceSampleRate
            ))
        }
        microphone.onWriteError = { error in
            failureHandler?(.microphone, error)
        }
        do {
            try microphone.startRecording(toOutputFile: url, deviceID: deviceID)
        } catch {
            microphone.onTimestampedAudioChunk = nil
            microphone.onDroppedInputFrames = nil
            microphone.onWriteError = nil
            throw error
        }
    }

    func startSystemAudio(writingTo url: URL, target: MeetingCaptureTarget) throws {
        guard #available(macOS 14.2, *) else {
            throw MeetingRecordingSession.SessionError.systemAudioUnavailable
        }

        try systemWriter.open(at: url)
        let chunkHandler = onChunk
        let failureHandler = onFailure
        let interruptionHandler = onInterruption
        let dropHandler = onDroppedFrames
        let stateHandler = onStateChange
        systemWriter.onChunk = { data, timestamp in
            chunkHandler?(.init(
                source: .systemAudio,
                data: data,
                hostTimeNanos: timestamp.hostTimeNanos,
                sampleTime: timestamp.sampleTime,
                sourceSampleRate: timestamp.sourceSampleRate,
                frameCount: data.count / MemoryLayout<Int16>.size
            ))
        }
        systemWriter.onError = { error in failureHandler?(.systemAudio, error) }
        systemWriter.onDroppedFrames = { frames, timestamp in
            dropHandler?(.init(
                source: .systemAudio,
                droppedFrames: frames,
                hostTimeNanos: timestamp.hostTimeNanos,
                sourceSampleTime: timestamp.sampleTime,
                sourceSampleRate: timestamp.sourceSampleRate
            ))
        }

        let tap = SystemAudioTap()
        tap.realtimeSink = systemWriter
        switch target {
        case .application(let bundleID, _, let processID):
            tap.captureScope = .application(processID: processID, bundleID: bundleID)
        case .allSystemAudio:
            tap.captureScope = .allSystemAudio
        }
        tap.onCaptureLost = { error in failureHandler?(.systemAudio, error) }
        tap.onCaptureWaiting = { error in
            stateHandler?(.systemAudio, .degraded, error.localizedDescription)
            if self.systemWriter.hasCapturedSignal {
                interruptionHandler?(.systemAudio, error)
            }
        }
        tap.onCaptureRestored = {
            stateHandler?(.systemAudio, .capturing, nil)
        }

        do {
            try tap.start()
            systemTap = tap
        } catch {
            systemWriter.onChunk = nil
            systemWriter.onError = nil
            systemWriter.onDroppedFrames = nil
            systemWriter.close()
            throw error
        }
    }

    @discardableResult
    func switchMicrophone(
        to deviceID: AudioDeviceID,
        beforeRestart: () -> Void
    ) throws -> Bool {
        guard !microphone.isCurrentlyRecording || microphone.currentDevice != deviceID else {
            return false
        }
        try microphone.switchDevice(to: deviceID, beforeRestart: beforeRestart)
        return true
    }

    func stopMicrophone() {
        microphone.stopRecording()
        microphone.onAudioChunk = nil
        microphone.onTimestampedAudioChunk = nil
        microphone.onDroppedInputFrames = nil
        microphone.onWriteError = nil
    }

    func stopSystemAudio() {
        if #available(macOS 14.2, *) {
            systemTap?.stop()
            systemTap = nil
        }
        // The tap can no longer publish; drain every accepted slot while this generation's
        // snapshotted callbacks are still installed, then clear them.
        systemWriter.close()
        systemWriter.onChunk = nil
        systemWriter.onError = nil
        systemWriter.onDroppedFrames = nil
    }

    private static func hostTimeNanos(from timeStamp: AudioTimeStamp) -> UInt64? {
        guard timeStamp.mFlags.contains(.hostTimeValid) else { return nil }
        return AudioConvertHostTimeToNanos(timeStamp.mHostTime)
    }

    private static func sampleTime(from timeStamp: AudioTimeStamp) -> Double? {
        timeStamp.mFlags.contains(.sampleTimeValid) ? timeStamp.mSampleTime : nil
    }

}
