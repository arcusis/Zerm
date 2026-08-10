import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

protocol SystemAudioRealtimeSink: AnyObject {
    /// Called before the IOProc is installed, so every buffer needed by the realtime producer is
    /// allocated before capture begins.
    func prepareRealtimeInput(format: AVAudioFormat)
    func enqueueRealtimeInput(
        _ input: UnsafePointer<AudioBufferList>,
        timestamp: AudioTimeStamp
    )
}

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

    enum CaptureScope: Equatable {
        case application(processID: Int32, bundleID: String)
        case allSystemAudio
    }

    enum TapError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case noDefaultOutputDevice
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case formatUnavailable(OSStatus)
        case processUnavailable(Int32)
        case outputDeviceChanged
        case selectedApplicationAudioChanged

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                return String(localized: "Could not tap system audio (status \(status)). Zerm may be missing the audio recording permission.")
            case .noDefaultOutputDevice:
                return String(localized: "No audio output device is available to record from.")
            case .aggregateCreationFailed(let status):
                return String(localized: "Could not assemble the system audio device (status \(status)).")
            case .ioProcFailed(let status):
                return String(localized: "Could not start reading system audio (status \(status)).")
            case .formatUnavailable(let status):
                return String(localized: "Could not read the system audio format (status \(status)).")
            case .processUnavailable(let processID):
                return String(localized: "The selected meeting application is no longer available (process \(processID)).")
            case .outputDeviceChanged:
                return String(localized: "The audio output changed while system audio was being recorded.")
            case .selectedApplicationAudioChanged:
                return String(localized: "The selected application's audio processes changed while recording.")
            }
        }
    }

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "SystemAudioTap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// The tap's native format, known only once the tap exists.
    private(set) var format: AVAudioFormat?

    /// The production path is a preallocated sink rather than a buffer callback: constructing an
    /// AVAudioPCMBuffer or invoking arbitrary clients in the IOProc is not realtime-safe.
    weak var realtimeSink: (any SystemAudioRealtimeSink)?

    private var isRunning = false

    /// Every lifecycle and Core Audio object mutation is confined to this queue. Public start and
    /// stop remain synchronous, but use queue-specific reentrancy so a loss callback can stop the
    /// tap without deadlocking. Listener callbacks are already delivered on this same queue.
    private let controlQueue = DispatchQueue(label: "com.arcusis.zerm.system-tap-control")
    private let controlQueueKey = DispatchSpecificKey<UInt8>()
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var processMonitor: DispatchSourceTimer?
    private var captureRetryMonitor: DispatchSourceTimer?
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var capturedProcessObjects = Set<AudioObjectID>()
    private var processUnavailableReported = false
    private var captureRequested = false
    private var captureGeneration: UInt64 = 0

    /// Raised when the aggregate had to be rebuilt and could not be brought back.
    var onCaptureLost: ((Error) -> Void)?
    /// A recoverable state: the selected process or output aggregate is temporarily absent.
    var onCaptureWaiting: ((Error) -> Void)?
    /// Raised after a waiting capture has successfully attached again.
    var onCaptureRestored: (() -> Void)?

    /// Zerm's own output — Read Aloud, UI sounds — is excluded, so a recording never captures
    /// the app talking to itself.
    var excludesOwnProcess = true

    /// Selected applications are the safe default. Global capture is an explicit fallback and
    /// may include unrelated notifications, music or other applications.
    var captureScope: CaptureScope = .allSystemAudio

    init() {
        controlQueue.setSpecific(key: controlQueueKey, value: 1)
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() throws {
        try onControlQueue {
            try startOnControlQueue()
        }
    }

    private func startOnControlQueue() throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard !captureRequested else { return }
        captureGeneration &+= 1
        captureRequested = true
        do {
            try activateCaptureResources()
            installProcessMonitorIfNeeded()
        } catch {
            if let tapError = error as? TapError,
               case .processUnavailable = tapError,
               case .application = captureScope {
                // The chosen app may not have opened an audio process yet. Keep the writer and
                // process monitor alive so joining a call later attaches without restarting the
                // meeting or sacrificing the microphone track.
                installProcessMonitorIfNeeded()
                processUnavailableReported = true
                onCaptureWaiting?(error)
                return
            }
            captureRequested = false
            teardown()
            throw error
        }
    }

    private func activateCaptureResources() throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        let createdTap = tapID == kAudioObjectUnknown
        if createdTap {
            try createTap()
            if let format { realtimeSink?.prepareRealtimeInput(format: format) }
        }
        do {
            try createAggregateDevice()
            try attachIOProc()
            let status = AudioDeviceStart(aggregateID, ioProcID)
            guard status == noErr else { throw TapError.ioProcFailed(status) }
        } catch {
            teardownAggregate()
            throw error
        }
        isRunning = true
        processUnavailableReported = false
        cancelCaptureRetry()
        installDefaultDeviceListener()
        onCaptureRestored?()
        logger.notice("System audio tap running (tap \(self.tapID, privacy: .public), aggregate \(self.aggregateID, privacy: .public))")
    }

    // MARK: - Following the default output device

    /// The aggregate is built around whichever device was default when recording started, so it
    /// stops carrying audio the moment that changes — headphones in, AirPlay out, a call moving
    /// to a headset. Nothing reports an error when this happens: the IOProc keeps firing and the
    /// samples simply go quiet, which on a long meeting means silently losing the far side for
    /// the rest of the call. So the change is watched for and the aggregate rebuilt underneath.
    private func installDefaultDeviceListener() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard deviceListener == nil else { return }
        let generation = captureGeneration
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.captureGeneration == generation else { return }
            self.rebuildForNewDefaultDevice()
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
        dispatchPrecondition(condition: .onQueue(controlQueue))
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
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard captureRequested, isRunning else { return }
        logger.notice("Default output device changed; rebuilding the system audio aggregate")
        onCaptureWaiting?(TapError.outputDeviceChanged)
        teardownAggregate()

        do {
            // The tap itself is global and survives; only the aggregate is bound to a device.
            try activateCaptureResources()
            logger.notice("System audio aggregate rebuilt on the new default device")
        } catch {
            isRunning = false
            logger.error("Could not follow the default device change: \(error.localizedDescription, privacy: .public)")
            onCaptureWaiting?(error)
            scheduleCaptureRetry()
        }
    }

    func stop() {
        onControlQueue {
            stopOnControlQueue()
        }
    }

    private func stopOnControlQueue() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard captureRequested || isRunning || tapID != kAudioObjectUnknown else { return }
        captureGeneration &+= 1
        captureRequested = false
        removeDefaultDeviceListener()
        processMonitor?.cancel()
        processMonitor = nil
        cancelCaptureRetry()
        removeProcessListListener()
        teardown()
        isRunning = false
        logger.notice("System audio tap stopped")
    }

    private func onControlQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            return try operation()
        }
        return try controlQueue.sync(execute: operation)
    }

    private func teardown() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        teardownAggregate()

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        format = nil
        capturedProcessObjects = []
    }

    private func teardownAggregate() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
    }

    // MARK: - Tap

    private func createTap() throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        let description: CATapDescription
        switch captureScope {
        case .application(let processID, let bundleID):
            let objectIDs = Self.processObjectIDs(for: processID, bundleID: bundleID)
            guard !objectIDs.isEmpty else {
                throw TapError.processUnavailable(processID)
            }
            capturedProcessObjects = Set(objectIDs)
            processUnavailableReported = false
            description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        case .allSystemAudio:
            if excludesOwnProcess,
               let ownObject = Self.processObjectID(for: ProcessInfo.processInfo.processIdentifier) {
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownObject])
            } else {
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            }
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

    private func installProcessMonitorIfNeeded() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard case .application(let processID, let bundleID) = captureScope else { return }
        guard processMonitor == nil else { return }
        let generation = captureGeneration
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.captureGeneration == generation else { return }
            self.evaluateSelectedProcesses(processID: processID, bundleID: bundleID)
        }
        let listenerStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener
        )
        if listenerStatus == noErr {
            processListListener = listener
        } else {
            logger.error("Could not observe Core Audio process changes (status \(listenerStatus, privacy: .public)); using periodic recovery checks")
        }

        // A periodic check complements the property listener: some browser helper churn updates
        // bundle membership without a useful notification on older 14.x point releases.
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.captureGeneration == generation else { return }
            self.evaluateSelectedProcesses(processID: processID, bundleID: bundleID)
        }
        processMonitor = timer
        timer.resume()
    }

    private func removeProcessListListener() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard let processListListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, processListListener
        )
        self.processListListener = nil
    }

    private func evaluateSelectedProcesses(processID: pid_t, bundleID: String) {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard captureRequested else { return }
        let current = Set(Self.processObjectIDs(for: processID, bundleID: bundleID))
        guard !current.isEmpty else {
            if !processUnavailableReported {
                processUnavailableReported = true
                if isRunning {
                    removeDefaultDeviceListener()
                    teardown()
                }
                onCaptureWaiting?(TapError.processUnavailable(processID))
            }
            return
        }
        if !isRunning {
            recoverCaptureIfPossible()
            return
        }
        guard current != capturedProcessObjects else { return }
        rebuildForSelectedProcesses()
    }

    private func rebuildForSelectedProcesses() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard isRunning else { return }
        logger.notice("Selected application audio processes changed; rebuilding process tap")
        onCaptureWaiting?(TapError.selectedApplicationAudioChanged)
        removeDefaultDeviceListener()
        teardown()
        do {
            try activateCaptureResources()
        } catch {
            logger.error("Could not follow selected application process change: \(error.localizedDescription, privacy: .public)")
            onCaptureWaiting?(error)
            scheduleCaptureRetry()
        }
    }

    private func scheduleCaptureRetry() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard captureRequested, captureRetryMonitor == nil else { return }
        let generation = captureGeneration
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.captureGeneration == generation else { return }
            self.recoverCaptureIfPossible()
        }
        captureRetryMonitor = timer
        timer.resume()
    }

    private func cancelCaptureRetry() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        captureRetryMonitor?.cancel()
        captureRetryMonitor = nil
    }

    private func recoverCaptureIfPossible() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard captureRequested, !isRunning else {
            if isRunning { cancelCaptureRetry() }
            return
        }
        do {
            try activateCaptureResources()
        } catch {
            if let tapError = error as? TapError,
               case .processUnavailable = tapError {
                if !processUnavailableReported {
                    processUnavailableReported = true
                    onCaptureWaiting?(error)
                }
            } else {
                logger.error("System audio capture is still waiting to recover: \(error.localizedDescription, privacy: .public)")
                onCaptureWaiting?(error)
                scheduleCaptureRetry()
            }
        }
    }

    // MARK: - Aggregate device

    private func createAggregateDevice() throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
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
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard format != nil else {
            throw TapError.formatUnavailable(OSStatus(kAudioHardwareUnspecifiedError))
        }

        let realtimeSink = realtimeSink
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [realtimeSink] _, inInputData, inInputTime, _, _ in
            realtimeSink?.enqueueRealtimeInput(inInputData, timestamp: inInputTime.pointee)
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

    /// Includes helper processes that share the selected application's bundle-ID namespace.
    /// Chromium and several call apps render audio in a helper rather than their UI process;
    /// tapping only the PID would produce a healthy-looking but silent track.
    private static func processObjectIDs(for pid: pid_t, bundleID: String) -> [AudioObjectID] {
        var result = Set<AudioObjectID>()
        if let direct = processObjectID(for: pid) { result.insert(direct) }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount
        ) == noErr, byteCount > 0 else { return Array(result) }

        var objects = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        let listStatus: OSStatus = objects.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return OSStatus(kAudioHardwareUnspecifiedError)
            }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                baseAddress
            )
        }
        guard listStatus == noErr else { return Array(result) }

        for object in objects {
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &size, $0)
            }
            guard status == noErr else { continue }
            let candidate = value as String
            if candidate == bundleID || candidate.hasPrefix(bundleID + ".") {
                result.insert(object)
            }
        }
        return Array(result)
    }
}
