import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Captures everything the machine is playing back — the far side of a Teams, Meet or Signal
/// call — as an audio stream.
///
/// Uses a Core Audio process tap rather than ScreenCaptureKit or an installed virtual device.
/// A tap needs no kernel extension, no driver the user has to install, and no screen-recording
/// permission; it is the supported route from macOS 14.2 onward, which the 14.4 deployment
/// target already clears.
///
/// A tap on its own produces nothing. It has to be aggregated with a real output device, and
/// the aggregate is what an IOProc can be attached to — hence the two-object dance in `start()`.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {

    enum TapError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case noDefaultOutputDevice
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case formatUnavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                return "Could not tap system audio (status \(status)). Zerm may be missing the audio recording permission."
            case .noDefaultOutputDevice:
                return "No audio output device is available to record from."
            case .aggregateCreationFailed(let status):
                return "Could not assemble the system audio device (status \(status))."
            case .ioProcFailed(let status):
                return "Could not start reading system audio (status \(status))."
            case .formatUnavailable(let status):
                return "Could not read the system audio format (status \(status))."
            }
        }
    }

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "SystemAudioTap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// The tap's native format, known only once the tap exists.
    private(set) var format: AVAudioFormat?

    /// Delivered on a realtime Core Audio thread. Do no allocation or locking of consequence here.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private(set) var isRunning = false

    /// Serialises start/stop against the default-device listener, which fires on its own queue.
    private let controlQueue = DispatchQueue(label: "com.arcusis.zerm.system-tap-control")
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// Raised when the aggregate had to be rebuilt and could not be brought back.
    var onCaptureLost: ((Error) -> Void)?

    /// Zerm's own output — Read Aloud, UI sounds — is excluded, so a recording never captures
    /// the app talking to itself.
    var excludesOwnProcess = true

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        try createTap()
        do {
            try createAggregateDevice()
            try attachIOProc()
        } catch {
            // Never leave a live tap behind on a partial failure; it would linger in Core Audio
            // for the lifetime of the process.
            teardown()
            throw error
        }

        let status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw TapError.ioProcFailed(status)
        }

        isRunning = true
        installDefaultDeviceListener()
        logger.notice("System audio tap running (tap \(self.tapID, privacy: .public), aggregate \(self.aggregateID, privacy: .public))")
    }

    // MARK: - Following the default output device

    /// The aggregate is built around whichever device was default when recording started, so it
    /// stops carrying audio the moment that changes — headphones in, AirPlay out, a call moving
    /// to a headset. Nothing reports an error when this happens: the IOProc keeps firing and the
    /// samples simply go quiet, which on a long meeting means silently losing the far side for
    /// the rest of the call. So the change is watched for and the aggregate rebuilt underneath.
    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.controlQueue.async { self?.rebuildForNewDefaultDevice() }
        }
        deviceListener = listener
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener
        )
        if status != noErr {
            logger.error("Could not watch the default output device (status \(status, privacy: .public)); a device change will silently stop system capture")
            deviceListener = nil
        }
    }

    private func removeDefaultDeviceListener() {
        guard let deviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, deviceListener
        )
        self.deviceListener = nil
    }

    private func rebuildForNewDefaultDevice() {
        guard isRunning else { return }
        logger.notice("Default output device changed; rebuilding the system audio aggregate")

        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        do {
            // The tap itself is global and survives; only the aggregate is bound to a device.
            try createAggregateDevice()
            try attachIOProc()
            let status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw TapError.ioProcFailed(status) }
            logger.notice("System audio aggregate rebuilt on the new default device")
        } catch {
            isRunning = false
            logger.error("Could not follow the default device change: \(error.localizedDescription, privacy: .public)")
            onCaptureLost?(error)
        }
    }

    func stop() {
        guard isRunning || tapID != kAudioObjectUnknown else { return }
        removeDefaultDeviceListener()
        if isRunning, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        teardown()
        isRunning = false
        logger.notice("System audio tap stopped")
    }

    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        format = nil
    }

    // MARK: - Tap

    private func createTap() throws {
        let description: CATapDescription
        if excludesOwnProcess, let ownObject = Self.processObjectID(for: ProcessInfo.processInfo.processIdentifier) {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownObject])
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.name = "Zerm Meeting Capture"
        // Private keeps the tap out of every other app's device list, and unmuted means the
        // user still hears the call normally while it is being recorded.
        description.isPrivate = true
        description.muteBehavior = .unmuted

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(status)
        }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard formatStatus == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.formatUnavailable(formatStatus)
        }
        self.format = format
        logger.notice("Tap format \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
    }

    // MARK: - Aggregate device

    private func createAggregateDevice() throws {
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            throw TapError.noDefaultOutputDevice
        }
        guard let tapUID = tapUID() else {
            throw TapError.aggregateCreationFailed(OSStatus(kAudioHardwareUnspecifiedError))
        }

        let aggregateUID = "com.arcusis.zerm.meeting-tap.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Zerm Meeting Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Private so the aggregate never shows up in Sound preferences or another app's
            // device picker while a recording is running.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            throw TapError.aggregateCreationFailed(status)
        }
    }

    private func attachIOProc() throws {
        guard let format else {
            throw TapError.formatUnavailable(OSStatus(kAudioHardwareUnspecifiedError))
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let handler = self.onBuffer else { return }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            handler(buffer)
        }

        guard status == noErr, ioProcID != nil else {
            throw TapError.ioProcFailed(status)
        }
    }

    // MARK: - Core Audio lookups

    private func tapUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? uid as String : nil
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, $0)
        }
        return status == noErr ? uid as String : nil
    }

    /// Core Audio identifies processes by its own object IDs, not by pid, so excluding an
    /// application from a tap means translating the pid first.
    private static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputPID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inputPID,
            &size,
            &objectID
        )
        return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
    }
}
