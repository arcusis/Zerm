import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Atomics
import os

// MARK: - Core Audio Recorder (AUHAL-based, does not change system default device)
final class CoreAudioRecorder: @unchecked Sendable {

    struct TimestampedAudioChunk: @unchecked Sendable {
        let data: Data
        let timeStamp: AudioTimeStamp
        let frameCount: Int
        let sampleRate: Double
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "CoreAudioRecorder")

    private var audioUnit: AudioUnit?
    private var audioFile: ExtAudioFileRef?

    private var isRecording = false
    private var currentDeviceID: AudioDeviceID = 0
    private var recordingURL: URL?

    // Device format (what the hardware provides)
    private var deviceFormat = AudioStreamBasicDescription()
    // Output format (16kHz mono PCM Int16 for transcription)
    private var outputFormat = AudioStreamBasicDescription()

    // Conversion buffer
    private var conversionBuffer: UnsafeMutablePointer<Int16>?
    private var conversionBufferSize: UInt32 = 0
    /// Fractional input sample index carried across RT callbacks so 48k→16k
    /// resampling has continuous phase (avoids a click every buffer).
    private var resampleInputCursor: Double = 0
    /// Last mono sample from the previous buffer for boundary interpolation.
    private var resampleLastSample: Float32 = 0
    private var hasResampleHistory = false

    // Audio metering (thread-safe)
    private let meterLock = NSLock()
    private var _averagePower: Float = -160.0
    private var _peakPower: Float = -160.0
    /// Monotonic timestamp of the last successful input callback. Lets the engine
    /// detect a silently-dropped capture: if the audio unit dies (device removed,
    /// render error) the callback stops firing while `isRecording` stays true.
    private let lastInputUptimeNanos = ManagedAtomic<UInt64>(0)

    var averagePower: Float {
        meterLock.lock()
        defer { meterLock.unlock() }
        return _averagePower
    }

    var peakPower: Float {
        meterLock.lock()
        defer { meterLock.unlock() }
        return _peakPower
    }

    /// Seconds since the last input callback fired, or `nil` if none has yet.
    /// A value that keeps climbing while recording means the capture has stalled.
    var secondsSinceLastInput: Double? {
        let last = lastInputUptimeNanos.load(ordering: .relaxed)
        guard last != 0 else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now > last else { return 0 }
        return Double(now - last) / 1_000_000_000.0
    }

    // Pre-allocated render buffer (to avoid malloc in real-time callback)
    private var renderBuffer: UnsafeMutablePointer<Float32>?
    private var renderBufferSize: UInt32 = 0

    /// Preallocated SPSC handoff. The AUHAL callback only renders, copies into a vacant slot,
    /// publishes an index and signals the already-running worker. Resampling, metering, file IO,
    /// Data creation, locks and Swift client closures all happen on the worker.
    private struct RealtimeSlotMetadata {
        var timestamp = AudioTimeStamp()
        var frames: UInt32 = 0
        var channels: UInt32 = 0
        var droppedInputFrames: UInt64 = 0
        var dropHostTimeNanos: UInt64 = 0
        var dropSourceSampleTimeBits: UInt64 = 0
    }
    private static let realtimeSlotCount: UInt64 = 32
    private let handoffWriteIndex = ManagedAtomic<UInt64>(0)
    private let handoffReadIndex = ManagedAtomic<UInt64>(0)
    private let handoffRunning = ManagedAtomic<Bool>(false)
    private let pendingDroppedInputFrames = ManagedAtomic<UInt64>(0)
    private let pendingDropHostTimeNanos = ManagedAtomic<UInt64>(0)
    private let pendingDropSourceSampleTimeBits = ManagedAtomic<UInt64>(UInt64.max)
    private let handoffSemaphore = DispatchSemaphore(value: 0)
    private let handoffQueue = DispatchQueue(
        label: "com.arcusis.zerm.microphone-track-writer",
        qos: .userInitiated
    )
    private var handoffSamples: UnsafeMutablePointer<Float32>?
    private var handoffMetadata: UnsafeMutablePointer<RealtimeSlotMetadata>?
    private var handoffSamplesPerSlot = 0

    // Per-session capture diagnostics. The real-time callback only touches the
    // atomics; the session dB accumulation rides the meterLock section that is
    // already taken on every callback.
    private let statCallbacks = ManagedAtomic<UInt64>(0)
    private let statFramesRendered = ManagedAtomic<UInt64>(0)
    private let statFramesWritten = ManagedAtomic<UInt64>(0)
    private let statRenderErrors = ManagedAtomic<UInt64>(0)
    private let statOverflows = ManagedAtomic<UInt64>(0)
    private let statWriteErrors = ManagedAtomic<UInt64>(0)
    private let statLastRenderStatus = ManagedAtomic<Int32>(0)
    private let statLastWriteStatus = ManagedAtomic<Int32>(0)
    private var _sessionPeakDb: Float = -160.0
    private var _sessionAvgDbSum: Double = 0
    private var _sessionMeterCount: UInt64 = 0
    private var sessionStartDate: Date?
    private var sessionDeviceName = "Unknown"

    /// Called on the audio thread with raw PCM data (16-bit, 16kHz, mono) for streaming.
    ///
    /// Lock-guarded because the render callback reads this on the realtime audio
    /// thread while the transcription engine swaps it from the main actor *during*
    /// a live recording (it installs the streaming callback once the session has
    /// prepared, and clears it when there is none). A closure is a two-word value,
    /// so an unsynchronized swap can be read torn — context from one closure paired
    /// with the function pointer of another.
    private let audioChunkLock = NSLock()
    private var _onAudioChunk: ((_ data: Data) -> Void)?
    private var _onTimestampedAudioChunk: ((TimestampedAudioChunk) -> Void)?
    private var _onDroppedInputFrames: ((Int64, UInt64?, Double?, Double) -> Void)?
    private var _onWriteError: ((Error) -> Void)?
    var onAudioChunk: ((_ data: Data) -> Void)? {
        get {
            audioChunkLock.lock()
            defer { audioChunkLock.unlock() }
            return _onAudioChunk
        }
        set {
            audioChunkLock.lock()
            _onAudioChunk = newValue
            audioChunkLock.unlock()
        }
    }

    var onTimestampedAudioChunk: ((TimestampedAudioChunk) -> Void)? {
        get {
            audioChunkLock.lock()
            defer { audioChunkLock.unlock() }
            return _onTimestampedAudioChunk
        }
        set {
            audioChunkLock.lock()
            _onTimestampedAudioChunk = newValue
            audioChunkLock.unlock()
        }
    }

    var onDroppedInputFrames: ((Int64, UInt64?, Double?, Double) -> Void)? {
        get {
            audioChunkLock.lock()
            defer { audioChunkLock.unlock() }
            return _onDroppedInputFrames
        }
        set {
            audioChunkLock.lock()
            _onDroppedInputFrames = newValue
            audioChunkLock.unlock()
        }
    }

    /// Delivered on the recorder's non-realtime handoff worker. A failed file write is not an
    /// audio delivery: callers must mark the source failed and must not advance durable clocks.
    var onWriteError: ((Error) -> Void)? {
        get {
            audioChunkLock.lock()
            defer { audioChunkLock.unlock() }
            return _onWriteError
        }
        set {
            audioChunkLock.lock()
            _onWriteError = newValue
            audioChunkLock.unlock()
        }
    }

    // MARK: - Initialization

    init() {}

    deinit {
        stopRecording()
    }

    // MARK: - Public Interface

    /// Starts recording from the specified device to the given URL (WAV format)
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws {
        // Stop any existing recording
        stopRecording()

        if deviceID == 0 {
            logger.error("Cannot start recording - no valid audio device (deviceID is 0)")
            dbg("startRecording FAILED: no valid audio device (deviceID is 0)")
            throw CoreAudioRecorderError.failedToSetDevice(status: 0)
        }

        // Validate device still exists before proceeding with setup
        guard isDeviceAvailable(deviceID) else {
            logger.error("Cannot start recording - device \(deviceID, privacy: .public) is no longer available")
            dbg("startRecording FAILED: device \(deviceID) is no longer available")
            throw CoreAudioRecorderError.deviceNotAvailable
        }

        currentDeviceID = deviceID
        recordingURL = url
        resetSessionStats()

        logger.notice("🎙️ Starting recording from device \(deviceID, privacy: .public)")

        // This is the user-visible "press hotkey → actually capturing" latency, so a
        // regression here needs to be visible in the field log, not just in a profiler.
        let startedAt = ProcessInfo.processInfo.systemUptime

        logDeviceDetails(deviceID: deviceID)

        // Step 1: Create and configure the AudioUnit (AUHAL)
        try createAudioUnit()

        // Step 2: Set the input device (does NOT change system default)
        try setInputDevice(deviceID)

        // Step 3: Configure formats
        try configureFormats()

        // Step 4: Set up the input callback
        try setupInputCallback()

        // Step 5: Create the output file
        try createOutputFile(at: url)

        // Step 6: Start the worker before AUHAL can publish its first buffer.
        startRealtimeHandoffWorker()
        isRecording = true
        do {
            try startAudioUnit()
        } catch {
            isRecording = false
            stopRealtimeHandoffWorker()
            throw error
        }

        logger.notice("⏱️ startRecording: \((ProcessInfo.processInfo.systemUptime - startedAt) * 1000, privacy: .public) ms")

        resampleInputCursor = 0
        hasResampleHistory = false
        resampleLastSample = 0
        dbg("startRecording: audio unit running, device=\(deviceID) file=\(url.lastPathComponent)")
    }

    /// Stops the current recording
    func stopRecording() {
        guard isRecording || audioUnit != nil else {
            logger.notice("stopRecording: skipped, not recording and no audio unit")
            return
        }
        logger.notice("stopRecording: stopping core audio recorder")
        let wasRecording = isRecording
        let sessionURL = recordingURL

        // Stop and dispose AudioUnit
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }


        // AUHAL can no longer publish. Drain every accepted slot before closing the file.
        stopRealtimeHandoffWorker()

        // Close audio file
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
        if let sessionURL {
            RecordingAudioStore.synchronize(sessionURL)
        }

        // Free conversion buffer
        if let buffer = conversionBuffer {
            buffer.deallocate()
            conversionBuffer = nil
            conversionBufferSize = 0
        }

        // Free render buffer
        if let buffer = renderBuffer {
            buffer.deallocate()
            renderBuffer = nil
            renderBufferSize = 0
        }
        releaseRealtimeHandoff()

        if wasRecording {
            dbg("session summary: \(sessionSummary(url: sessionURL))")
        }

        isRecording = false
        currentDeviceID = 0
        recordingURL = nil

        // Reset meters
        meterLock.lock()
        _averagePower = -160.0
        _peakPower = -160.0
        meterLock.unlock()
        lastInputUptimeNanos.store(0, ordering: .relaxed)
    }

    var isCurrentlyRecording: Bool { isRecording }
    var currentRecordingURL: URL? { recordingURL }
    var currentDevice: AudioDeviceID { currentDeviceID }

    /// Switches to a new input device mid-recording without closing the file.
    ///
    /// The operation is transactional. Every failure attempts to fully configure and restart the
    /// prior device. If rollback is impossible (for example the old device was unplugged), the
    /// recorder is left explicitly stopped with device ID zero so a later device notification can
    /// retry rather than mistaking a dead AU for a healthy capture.
    func switchDevice(
        to newDeviceID: AudioDeviceID,
        beforeRestart: () -> Void = {}
    ) throws {
        guard let unit = audioUnit, audioFile != nil else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Don't switch if it's the same device
        guard !isRecording || newDeviceID != currentDeviceID else { return }

        let oldDeviceID = currentDeviceID
        let oldDeviceName = sessionDeviceName
        logger.notice("🎙️ Switching recording device from \(oldDeviceID, privacy: .public) to \(newDeviceID, privacy: .public)")
        dbg("switchDevice: \(oldDeviceID) → \(newDeviceID)")

        if isRecording {
            let status = AudioOutputUnitStop(unit)
            if status != noErr {
                logger.warning("🎙️ Warning: AudioOutputUnitStop returned \(status, privacy: .public)")
            }
        }
        isRecording = false
        stopRealtimeHandoffWorker()
        var markerEmitted = false
        let emitMarkerOnce = {
            guard !markerEmitted else { return }
            markerEmitted = true
            beforeRestart()
        }

        do {
            let newFormat = try configureAndStartStoppedAudioUnit(
                unit,
                deviceID: newDeviceID,
                beforeStart: emitMarkerOnce
            )
            currentDeviceID = newDeviceID
            sessionDeviceName = getDeviceStringProperty(
                deviceID: newDeviceID,
                selector: kAudioDevicePropertyDeviceNameCFString
            ) ?? "Unknown"
            logger.notice("🎙️ Successfully switched to device \(newDeviceID, privacy: .public)")
            dbg("switchDevice: switched to \(newDeviceID) (\(sessionDeviceName)), fmt=\(Int(newFormat.mSampleRate))Hz/\(newFormat.mChannelsPerFrame)ch")
        } catch {
            let migrationError = error
            logger.error("Microphone migration failed: \(error.localizedDescription, privacy: .public); attempting transactional rollback")
            do {
                guard oldDeviceID != 0, isDeviceAvailable(oldDeviceID) else {
                    throw CoreAudioRecorderError.deviceNotAvailable
                }
                _ = try configureAndStartStoppedAudioUnit(
                    unit,
                    deviceID: oldDeviceID,
                    beforeStart: emitMarkerOnce
                )
                currentDeviceID = oldDeviceID
                sessionDeviceName = oldDeviceName
                logger.notice("Microphone migration rolled back to device \(oldDeviceID, privacy: .public)")
            } catch {
                stopRealtimeHandoffWorker()
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                isRecording = false
                currentDeviceID = 0
                logger.error("Microphone migration rollback failed; capture is stopped and retryable: \(error.localizedDescription, privacy: .public)")
            }
            throw migrationError
        }
    }

    private func configureAndStartStoppedAudioUnit(
        _ unit: AudioUnit,
        deviceID: AudioDeviceID,
        beforeStart: () -> Void
    ) throws -> AudioStreamBasicDescription {
        AudioUnitUninitialize(unit)

        var device = deviceID
        var status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CoreAudioRecorderError.failedToSetDevice(status: status) }

        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &format,
            &formatSize
        )
        guard status == noErr else {
            throw CoreAudioRecorderError.failedToGetDeviceFormat(status: status)
        }
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw CoreAudioRecorderError.invalidDeviceFormat(
                sampleRate: format.mSampleRate,
                channels: format.mChannelsPerFrame
            )
        }

        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * format.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * format.mChannelsPerFrame,
            mChannelsPerFrame: format.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &callbackFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { throw CoreAudioRecorderError.failedToSetFormat(status: status) }

        prepareRealtimeBuffers(for: format)
        deviceFormat = format
        resampleInputCursor = 0
        hasResampleHistory = false
        resampleLastSample = 0

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw CoreAudioRecorderError.failedToInitialize(status: status)
        }
        startRealtimeHandoffWorker()
        beforeStart()
        isRecording = true
        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            isRecording = false
            stopRealtimeHandoffWorker()
            AudioUnitUninitialize(unit)
            throw CoreAudioRecorderError.failedToStart(status: status)
        }
        return format
    }

    private func prepareRealtimeBuffers(for format: AudioStreamBasicDescription) {
        let maxFrames: UInt32 = 4096
        let bufferSamples = maxFrames * format.mChannelsPerFrame
        if bufferSamples > renderBufferSize {
            renderBuffer?.deallocate()
            renderBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(bufferSamples))
            renderBufferSize = bufferSamples
        }
        allocateRealtimeHandoff(samplesPerSlot: Int(bufferSamples))

        let maxOutputFrames = UInt32(
            Double(maxFrames) * (outputFormat.mSampleRate / format.mSampleRate)
        ) + 1
        if maxOutputFrames > conversionBufferSize {
            conversionBuffer?.deallocate()
            conversionBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(maxOutputFrames))
            conversionBufferSize = maxOutputFrames
        }
    }

    // MARK: - AudioUnit Setup

    private func createAudioUnit() throws {
        // VoiceProcessingIO adds echo cancel + AGC (opt-in for noisy rooms).
        // Fall back to HALOutput when VPIO is unavailable or fails.
        let preferVPIO = UserDefaults.standard.bool(forKey: "UseVoiceProcessingIO")
        let subType: OSType = preferVPIO
            ? kAudioUnitSubType_VoiceProcessingIO
            : kAudioUnitSubType_HALOutput
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        var component = AudioComponentFindNext(nil, &desc)
        if component == nil, preferVPIO {
            logger.warning("VoiceProcessingIO unavailable — falling back to HALOutput")
            desc.componentSubType = kAudioUnitSubType_HALOutput
            component = AudioComponentFindNext(nil, &desc)
        }
        guard let component else {
            logger.error("AudioUnit not found - HAL Output component unavailable")
            throw CoreAudioRecorderError.audioUnitNotFound
        }
        if preferVPIO {
            dbg("createAudioUnit: VoiceProcessingIO enabled (echo cancel / AGC)")
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            logger.error("Failed to create AudioUnit instance: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToCreateAudioUnit(status: status)
        }

        self.audioUnit = audioUnit

        // Enable input on element 1 (input scope)
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1, // Element 1 = input
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        if status != noErr {
            logger.error("Failed to enable audio input: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToEnableInput(status: status)
        }

        // Disable output on element 0 (output scope)
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0, // Element 0 = output
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )

        if status != noErr {
            logger.error("Failed to disable audio output: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToDisableOutput(status: status)
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            logger.error("Failed to set input device \(deviceID, privacy: .public): \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetDevice(status: status)
        }
    }

    private func configureFormats() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        // Get the device's native format (input scope, element 1)
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &formatSize
        )

        if status != noErr {
            logger.error("Failed to get device format: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToGetDeviceFormat(status: status)
        }

        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0 else {
            logger.error("Invalid device format: sampleRate=\(self.deviceFormat.mSampleRate, privacy: .public) channels=\(self.deviceFormat.mChannelsPerFrame, privacy: .public)")
            throw CoreAudioRecorderError.invalidDeviceFormat(
                sampleRate: deviceFormat.mSampleRate,
                channels: deviceFormat.mChannelsPerFrame
            )
        }

        // Configure output format: 16kHz, mono, PCM Int16
        outputFormat = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        // Set callback format (Float32 for processing, then convert to Int16 for file)
        var callbackFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size) * deviceFormat.mChannelsPerFrame,
            mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &callbackFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        if status != noErr {
            logger.error("Failed to set audio format: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetFormat(status: status)
        }

        // Log format details
        let devSampleRate = deviceFormat.mSampleRate
        let devChannels = deviceFormat.mChannelsPerFrame
        let devBits = deviceFormat.mBitsPerChannel
        let outSampleRate = outputFormat.mSampleRate
        let outChannels = outputFormat.mChannelsPerFrame
        let outBits = outputFormat.mBitsPerChannel
        logger.notice("🎙️ Device format: sampleRate=\(devSampleRate, privacy: .public), channels=\(devChannels, privacy: .public), bitsPerChannel=\(devBits, privacy: .public)")
        logger.notice("🎙️ Output format: sampleRate=\(outSampleRate, privacy: .public), channels=\(outChannels, privacy: .public), bitsPerChannel=\(outBits, privacy: .public)")
        if devSampleRate != outSampleRate {
            logger.notice("🎙️ Converting: \(Int(devSampleRate), privacy: .public)Hz → \(Int(outSampleRate), privacy: .public)Hz")
        }
        dbg("formats: device=\(Int(devSampleRate))Hz/\(devChannels)ch/\(devBits)bit output=\(Int(outSampleRate))Hz/\(outChannels)ch/\(outBits)bit")

        // Pre-allocate buffers for real-time callback (avoid malloc in callback)
        let maxFrames: UInt32 = 4096
        let bufferSamples = maxFrames * deviceFormat.mChannelsPerFrame
        renderBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(bufferSamples))
        renderBufferSize = bufferSamples
        allocateRealtimeHandoff(samplesPerSlot: Int(bufferSamples))

        // Pre-allocate conversion buffer (output is always smaller due to downsampling)
        let maxOutputFrames = UInt32(Double(maxFrames) * (outputFormat.mSampleRate / deviceFormat.mSampleRate)) + 1
        conversionBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(maxOutputFrames))
        conversionBufferSize = maxOutputFrames
    }

    private func setupInputCallback() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        if status != noErr {
            logger.error("Failed to set input callback: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetCallback(status: status)
        }
    }

    private func createOutputFile(at url: URL) throws {
        // Remove existing file if any
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        // Create ExtAudioFile for writing
        var fileRef: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileWAVEType,
            &outputFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )

        if status != noErr {
            logger.error("Failed to create audio file at \(url.path, privacy: .public): \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToCreateFile(status: status)
        }

        audioFile = fileRef

        // Set client format (what we'll write)
        status = ExtAudioFileSetProperty(
            fileRef!,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &outputFormat
        )

        if status != noErr {
            logger.error("Failed to set file format: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToSetFileFormat(status: status)
        }
    }

    private func startAudioUnit() throws {
        guard let audioUnit = audioUnit else {
            throw CoreAudioRecorderError.audioUnitNotInitialized
        }

        var status = AudioUnitInitialize(audioUnit)
        if status != noErr {
            logger.error("Failed to initialize AudioUnit: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToInitialize(status: status)
        }

        // Measured on an M4 Max: AudioUnitInitialize ~10 ms, AudioOutputUnitStart ~43 ms.
        // The Start cost is the OS spinning the input device up and is not avoidable without
        // holding the microphone stream open between dictations — which would light the
        // privacy indicator permanently. Treat ~45 ms as the floor for this path.
        status = AudioOutputUnitStart(audioUnit)
        if status != noErr {
            logger.error("Failed to start AudioUnit: \(status, privacy: .public)")
            throw CoreAudioRecorderError.failedToStart(status: status)
        }
    }

    // MARK: - Input Callback

    private let inputCallback: AURenderCallback = { (
        inRefCon,
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames,
        ioData
    ) -> OSStatus in

        let recorder = Unmanaged<CoreAudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        return recorder.handleInputBuffer(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inBusNumber: inBusNumber,
            inNumberFrames: inNumberFrames
        )
    }

    private func handleInputBuffer(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {

        guard let audioUnit = audioUnit, isRecording, let renderBuf = renderBuffer else {
            return noErr
        }

        // Use pre-allocated buffer for input data
        let channelCount = deviceFormat.mChannelsPerFrame
        let requiredSamples = inNumberFrames * channelCount

        // Safety check - shouldn't happen with 4096 max frames
        guard requiredSamples <= renderBufferSize else {
            statOverflows.wrappingIncrement(ordering: .relaxed)
            return noErr
        }

        statCallbacks.wrappingIncrement(ordering: .relaxed)

        let bytesPerFrame = UInt32(MemoryLayout<Float32>.size) * channelCount
        let bufferSize = inNumberFrames * bytesPerFrame

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channelCount,
                mDataByteSize: bufferSize,
                mData: renderBuf
            )
        )

        // Render audio from the input
        let status = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            &bufferList
        )

        if status != noErr {
            statRenderErrors.wrappingIncrement(ordering: .relaxed)
            statLastRenderStatus.store(status, ordering: .relaxed)
            return status
        }

        statFramesRendered.wrappingIncrement(by: UInt64(inNumberFrames), ordering: .relaxed)
        lastInputUptimeNanos.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        enqueueRealtimeInput(
            renderBuf,
            frames: inNumberFrames,
            channels: channelCount,
            timestamp: inTimeStamp.pointee
        )

        return noErr
    }

    private func allocateRealtimeHandoff(samplesPerSlot: Int) {
        releaseRealtimeHandoff()
        guard samplesPerSlot > 0 else { return }
        handoffSamplesPerSlot = samplesPerSlot
        let sampleCapacity = samplesPerSlot * Int(Self.realtimeSlotCount)
        handoffSamples = .allocate(capacity: sampleCapacity)
        handoffMetadata = .allocate(capacity: Int(Self.realtimeSlotCount))
        handoffMetadata?.initialize(
            repeating: RealtimeSlotMetadata(),
            count: Int(Self.realtimeSlotCount)
        )
        handoffWriteIndex.store(0, ordering: .relaxed)
        handoffReadIndex.store(0, ordering: .relaxed)
        pendingDroppedInputFrames.store(0, ordering: .relaxed)
        pendingDropHostTimeNanos.store(0, ordering: .relaxed)
        pendingDropSourceSampleTimeBits.store(UInt64.max, ordering: .relaxed)
    }

    private func releaseRealtimeHandoff() {
        handoffSamples?.deallocate()
        handoffSamples = nil
        if let handoffMetadata {
            handoffMetadata.deinitialize(count: Int(Self.realtimeSlotCount))
            handoffMetadata.deallocate()
            self.handoffMetadata = nil
        }
        handoffSamplesPerSlot = 0
        handoffWriteIndex.store(0, ordering: .relaxed)
        handoffReadIndex.store(0, ordering: .relaxed)
    }

    /// Realtime-safe producer: no locks, heap allocation, filesystem access or client callback.
    private func enqueueRealtimeInput(
        _ samples: UnsafePointer<Float32>,
        frames: UInt32,
        channels: UInt32,
        timestamp: AudioTimeStamp
    ) {
        guard handoffRunning.load(ordering: .relaxed),
              let handoffSamples,
              let handoffMetadata else { return }
        let sampleCount = Int(frames * channels)
        guard sampleCount <= handoffSamplesPerSlot else {
            statOverflows.wrappingIncrement(ordering: .relaxed)
            accumulateDroppedInput(frames: frames, timestamp: timestamp)
            handoffSemaphore.signal()
            return
        }
        var write = handoffWriteIndex.load(ordering: .relaxed)
        let read = handoffReadIndex.load(ordering: .acquiring)
        guard write &- read < Self.realtimeSlotCount else {
            statOverflows.wrappingIncrement(ordering: .relaxed)
            accumulateDroppedInput(frames: frames, timestamp: timestamp)
            handoffSemaphore.signal()
            return
        }
        if pendingDroppedInputFrames.load(ordering: .acquiring) > 0 {
            publishPendingDrop(at: write, channels: channels)
            write &+= 1
            guard write &- read < Self.realtimeSlotCount else {
                statOverflows.wrappingIncrement(ordering: .relaxed)
                accumulateDroppedInput(frames: frames, timestamp: timestamp)
                handoffSemaphore.signal()
                return
            }
        }
        let slot = Int(write % Self.realtimeSlotCount)
        memcpy(
            handoffSamples.advanced(by: slot * handoffSamplesPerSlot),
            samples,
            sampleCount * MemoryLayout<Float32>.size
        )
        handoffMetadata[slot] = .init(
            timestamp: timestamp,
            frames: frames,
            channels: channels,
            droppedInputFrames: 0,
            dropHostTimeNanos: 0,
            dropSourceSampleTimeBits: 0
        )
        handoffWriteIndex.store(write &+ 1, ordering: .releasing)
        handoffSemaphore.signal()
    }

    private func startRealtimeHandoffWorker() {
        guard handoffSamples != nil, handoffMetadata != nil else { return }
        guard !handoffRunning.exchange(true, ordering: .acquiringAndReleasing) else { return }
        handoffQueue.async { [weak self] in self?.runRealtimeHandoffWorker() }
    }

    private func stopRealtimeHandoffWorker() {
        guard handoffRunning.exchange(false, ordering: .acquiringAndReleasing) else { return }
        handoffSemaphore.signal()
        handoffQueue.sync {}
    }

    private func runRealtimeHandoffWorker() {
        while true {
            handoffSemaphore.wait()
            drainRealtimeHandoff()
            if !handoffRunning.load(ordering: .acquiring),
               handoffReadIndex.load(ordering: .acquiring)
                    == handoffWriteIndex.load(ordering: .acquiring) {
                reportPendingDroppedInputFrames()
                return
            }
        }
    }

    private func drainRealtimeHandoff() {
        guard let handoffSamples, let handoffMetadata else { return }
        while true {
            let read = handoffReadIndex.load(ordering: .relaxed)
            let write = handoffWriteIndex.load(ordering: .acquiring)
            guard read < write else { break }
            let slot = Int(read % Self.realtimeSlotCount)
            let metadata = handoffMetadata[slot]
            if metadata.droppedInputFrames > 0 {
                reportDroppedInputFrames(metadata)
                handoffReadIndex.store(read &+ 1, ordering: .releasing)
                continue
            }
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: metadata.channels,
                    mDataByteSize: metadata.frames * metadata.channels
                        * UInt32(MemoryLayout<Float32>.size),
                    mData: handoffSamples.advanced(by: slot * handoffSamplesPerSlot)
                )
            )
            calculateMeters(from: &bufferList, frameCount: metadata.frames)
            convertAndWriteToFile(
                inputBuffer: &bufferList,
                frameCount: metadata.frames,
                timeStamp: metadata.timestamp
            )
            handoffReadIndex.store(read &+ 1, ordering: .releasing)
        }
    }

    private func accumulateDroppedInput(frames: UInt32, timestamp: AudioTimeStamp) {
        if pendingDroppedInputFrames.load(ordering: .relaxed) == 0 {
            let hostNanos = timestamp.mFlags.contains(.hostTimeValid)
                ? AudioConvertHostTimeToNanos(timestamp.mHostTime) : 0
            let sampleBits = timestamp.mFlags.contains(.sampleTimeValid)
                ? timestamp.mSampleTime.bitPattern : UInt64.max
            pendingDropHostTimeNanos.store(hostNanos, ordering: .relaxed)
            pendingDropSourceSampleTimeBits.store(sampleBits, ordering: .relaxed)
        }
        pendingDroppedInputFrames.wrappingIncrement(by: UInt64(frames), ordering: .releasing)
    }

    private func publishPendingDrop(at write: UInt64, channels: UInt32) {
        guard let handoffMetadata else { return }
        let dropped = pendingDroppedInputFrames.exchange(0, ordering: .acquiringAndReleasing)
        guard dropped > 0 else { return }
        let slot = Int(write % Self.realtimeSlotCount)
        handoffMetadata[slot] = .init(
            timestamp: AudioTimeStamp(),
            frames: 0,
            channels: channels,
            droppedInputFrames: dropped,
            dropHostTimeNanos: pendingDropHostTimeNanos.exchange(0, ordering: .acquiringAndReleasing),
            dropSourceSampleTimeBits: pendingDropSourceSampleTimeBits.exchange(UInt64.max, ordering: .acquiringAndReleasing)
        )
        handoffWriteIndex.store(write &+ 1, ordering: .releasing)
    }

    private func reportDroppedInputFrames(_ metadata: RealtimeSlotMetadata) {
        let outputFrames = Int64(
            (Double(metadata.droppedInputFrames) * outputFormat.mSampleRate
                / max(1, deviceFormat.mSampleRate)).rounded()
        )
        onDroppedInputFrames?(
            outputFrames,
            metadata.dropHostTimeNanos == 0 ? nil : metadata.dropHostTimeNanos,
            metadata.dropSourceSampleTimeBits == UInt64.max
                ? nil : Double(bitPattern: metadata.dropSourceSampleTimeBits),
            deviceFormat.mSampleRate
        )
    }

    private func reportPendingDroppedInputFrames() {
        let dropped = pendingDroppedInputFrames.exchange(0, ordering: .acquiringAndReleasing)
        guard dropped > 0 else { return }
        reportDroppedInputFrames(.init(
            timestamp: AudioTimeStamp(),
            frames: 0,
            channels: deviceFormat.mChannelsPerFrame,
            droppedInputFrames: dropped,
            dropHostTimeNanos: pendingDropHostTimeNanos.exchange(0, ordering: .acquiringAndReleasing),
            dropSourceSampleTimeBits: pendingDropSourceSampleTimeBits.exchange(UInt64.max, ordering: .acquiringAndReleasing)
        ))
    }

    private func calculateMeters(from bufferList: inout AudioBufferList, frameCount: UInt32) {
        guard let data = bufferList.mBuffers.mData else { return }
        guard frameCount > 0 else { return }

        let samples = data.assumingMemoryBound(to: Float32.self)
        let channelCount = Int(deviceFormat.mChannelsPerFrame)
        let totalSamples = Int(frameCount) * channelCount

        guard totalSamples > 0 else { return }

        var sum: Float = 0.0
        var peak: Float = 0.0

        for i in 0..<totalSamples {
            let sample = abs(samples[i])
            sum += sample * sample
            if sample > peak {
                peak = sample
            }
        }

        let rms = sqrt(sum / Float(totalSamples))
        let avgDb = 20.0 * log10(max(rms, 0.000001))
        let peakDb = 20.0 * log10(max(peak, 0.000001))

        meterLock.lock()
        _averagePower = avgDb
        _peakPower = peakDb
        if peakDb > _sessionPeakDb {
            _sessionPeakDb = peakDb
        }
        _sessionAvgDbSum += Double(avgDb)
        _sessionMeterCount += 1
        meterLock.unlock()
    }

    private func convertAndWriteToFile(
        inputBuffer: inout AudioBufferList,
        frameCount: UInt32,
        timeStamp: AudioTimeStamp
    ) {
        guard let file = audioFile else { return }

        let inputChannels = Int(deviceFormat.mChannelsPerFrame)
        let inputSampleRate = deviceFormat.mSampleRate
        let outputSampleRate = outputFormat.mSampleRate

        guard inputChannels > 0, inputSampleRate > 0, frameCount > 0 else { return }
        guard let inputData = inputBuffer.mBuffers.mData else { return }
        let inputSamples = inputData.assumingMemoryBound(to: Float32.self)

        // Mix to mono first. Prefer active (non-silent) channels so a dead stereo
        // channel doesn't dilute speech by −6 dB and trip false auto-stops.
        var mono = [Float32](repeating: 0, count: Int(frameCount))
        Self.mixToMono(inputSamples: inputSamples, frameCount: Int(frameCount), channels: inputChannels, output: &mono)

        let ratio = outputSampleRate / inputSampleRate
        guard ratio > 0, let outputBuffer = conversionBuffer else { return }

        var produced: UInt32 = 0
        if abs(inputSampleRate - outputSampleRate) < 0.5 {
            produced = UInt32(frameCount)
            guard produced <= conversionBufferSize else { return }
            for i in 0..<Int(frameCount) {
                outputBuffer[i] = Self.floatToInt16(mono[i])
            }
            resampleInputCursor = 0
            hasResampleHistory = false
        } else {
            // Continuous linear SRC with phase carry across RT buffers.
            let inputCount = Double(frameCount)
            var outIndex = 0
            var cursor = resampleInputCursor
            while cursor < inputCount && outIndex < Int(conversionBufferSize) {
                let idx = Int(cursor)
                let frac = Float32(cursor - Double(idx))
                let s1: Float32
                if idx < 0 {
                    s1 = hasResampleHistory ? resampleLastSample : mono[0]
                } else if idx < mono.count {
                    s1 = mono[idx]
                } else {
                    s1 = mono[mono.count - 1]
                }
                let s2: Float32
                if idx + 1 < mono.count {
                    s2 = mono[idx + 1]
                } else {
                    s2 = s1
                }
                outputBuffer[outIndex] = Self.floatToInt16(s1 + frac * (s2 - s1))
                outIndex += 1
                cursor += 1.0 / ratio
            }
            produced = UInt32(outIndex)
            // Carry fractional position into the next buffer relative to a new 0 origin.
            resampleInputCursor = cursor - inputCount
            if mono.count > 0 {
                resampleLastSample = mono[mono.count - 1]
                hasResampleHistory = true
            }
        }

        guard produced > 0 else { return }

        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: produced * 2,
                mData: outputBuffer
            )
        )

        let writeStatus = ExtAudioFileWrite(file, produced, &outputBufferList)
        if writeStatus != noErr {
            statWriteErrors.wrappingIncrement(ordering: .relaxed)
            statLastWriteStatus.store(writeStatus, ordering: .relaxed)
            logger.error("🎙️ ExtAudioFileWrite failed with status: \(writeStatus, privacy: .public)")
            onWriteError?(CoreAudioRecorderError.failedToWriteFile(status: writeStatus))
            return
        }
        statFramesWritten.wrappingIncrement(by: UInt64(produced), ordering: .relaxed)

        let byteCount = Int(produced) * MemoryLayout<Int16>.size
        let data = Data(bytes: outputBuffer, count: byteCount)
        onAudioChunk?(data)
        onTimestampedAudioChunk?(.init(
            data: data,
            timeStamp: timeStamp,
            frameCount: Int(produced),
            sampleRate: inputSampleRate
        ))
    }

    /// Mix multi-channel float samples to mono, skipping near-silent channels.
    private static func mixToMono(
        inputSamples: UnsafePointer<Float32>,
        frameCount: Int,
        channels: Int,
        output: inout [Float32]
    ) {
        guard channels > 0, frameCount > 0 else { return }
        if channels == 1 {
            for i in 0..<frameCount { output[i] = inputSamples[i] }
            return
        }

        var channelEnergy = [Float](repeating: 0, count: channels)
        for i in 0..<frameCount {
            for ch in 0..<channels {
                let s = inputSamples[i * channels + ch]
                channelEnergy[ch] += s * s
            }
        }
        let energyThreshold = channelEnergy.max().map { $0 * 0.05 } ?? 0
        var active: [Int] = []
        for ch in 0..<channels where channelEnergy[ch] > energyThreshold && channelEnergy[ch] > 1e-8 {
            active.append(ch)
        }
        if active.isEmpty { active = [0] }

        let scale = 1.0 / Float32(active.count)
        for i in 0..<frameCount {
            var sample: Float32 = 0
            for ch in active {
                sample += inputSamples[i * channels + ch]
            }
            output[i] = sample * scale
        }
    }

    private static func floatToInt16(_ sample: Float32) -> Int16 {
        let scaled = sample * 32767.0
        let clipped = max(-32768.0, min(32767.0, scaled))
        return Int16(clipped)
    }

    // MARK: - Session Diagnostics

    private func dbg(_ message: String) {
        DebugLogger.shared.log("CoreAudioRecorder", message)
    }

    private func resetSessionStats() {
        statCallbacks.store(0, ordering: .relaxed)
        statFramesRendered.store(0, ordering: .relaxed)
        statFramesWritten.store(0, ordering: .relaxed)
        statRenderErrors.store(0, ordering: .relaxed)
        statOverflows.store(0, ordering: .relaxed)
        statWriteErrors.store(0, ordering: .relaxed)
        statLastRenderStatus.store(0, ordering: .relaxed)
        statLastWriteStatus.store(0, ordering: .relaxed)
        meterLock.lock()
        _sessionPeakDb = -160.0
        _sessionAvgDbSum = 0
        _sessionMeterCount = 0
        meterLock.unlock()
        sessionStartDate = Date()
        sessionDeviceName = "Unknown"
    }

    /// Snapshot of the current session's capture counters, safe to call from
    /// any non-realtime thread.
    func debugSessionStats() -> String {
        meterLock.lock()
        let peak = _sessionPeakDb
        let avg = _sessionMeterCount > 0 ? Float(_sessionAvgDbSum / Double(_sessionMeterCount)) : -160.0
        meterLock.unlock()
        return "callbacks=\(statCallbacks.load(ordering: .relaxed)) "
            + "framesIn=\(statFramesRendered.load(ordering: .relaxed)) "
            + "framesOut=\(statFramesWritten.load(ordering: .relaxed)) "
            + "renderErrs=\(statRenderErrors.load(ordering: .relaxed)) "
            + "lastRenderErr=\(statLastRenderStatus.load(ordering: .relaxed)) "
            + "overflows=\(statOverflows.load(ordering: .relaxed)) "
            + "writeErrs=\(statWriteErrors.load(ordering: .relaxed)) "
            + "lastWriteErr=\(statLastWriteStatus.load(ordering: .relaxed)) "
            + String(format: "peak=%.1fdB avg=%.1fdB", peak, avg)
    }

    private func sessionSummary(url: URL?) -> String {
        let duration = sessionStartDate.map { Date().timeIntervalSince($0) } ?? 0
        var bytes: UInt64 = 0
        if let path = url?.path,
           let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 {
            bytes = size
        }
        return "session=\(url?.lastPathComponent ?? "?") device=\(currentDeviceID) name=\(sessionDeviceName) "
            + "fmt=\(Int(deviceFormat.mSampleRate))Hz/\(deviceFormat.mChannelsPerFrame)ch "
            + String(format: "dur=%.2fs ", duration)
            + debugSessionStats()
            + " bytes=\(bytes)"
    }

    // MARK: - Device Info Logging

    private func logDeviceDetails(deviceID: AudioDeviceID) {
        // Get device name
        let deviceName = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"

        // Get device UID
        let deviceUID = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "Unknown"

        // Get transport type
        let transportType = getTransportType(deviceID: deviceID)

        // Get manufacturer
        let manufacturer = getDeviceStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceManufacturerCFString) ?? "Unknown"

        logger.notice("🎙️ Device info: name=\(deviceName, privacy: .public), uid=\(deviceUID, privacy: .public)")
        logger.notice("🎙️ Device details: transport=\(transportType, privacy: .public), manufacturer=\(manufacturer, privacy: .public)")

        sessionDeviceName = deviceName
        dbg("device: id=\(deviceID) name=\(deviceName) uid=\(deviceUID) transport=\(transportType) manufacturer=\(manufacturer)")

        // Get buffer frame size
        if let bufferSize = getBufferFrameSize(deviceID: deviceID) {
            let latencyMs = (Double(bufferSize) / 48000.0) * 1000.0 // Approximate latency assuming 48kHz
            logger.notice("🎙️ Buffer size: \(bufferSize, privacy: .public) frames, ~latency: \(String(format: "%.1f", latencyMs), privacy: .public)ms")
        }
    }

    private func getDeviceStringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        AudioObjectProperty.string(deviceID, selector: selector)
    }

    private func getTransportType(deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &transportType
        )

        if status != noErr {
            return "Unknown"
        }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "Built-in"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeBluetooth:
            return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "Bluetooth LE"
        case kAudioDeviceTransportTypeAggregate:
            return "Aggregate"
        case kAudioDeviceTransportTypeVirtual:
            return "Virtual"
        case kAudioDeviceTransportTypePCI:
            return "PCI"
        case kAudioDeviceTransportTypeFireWire:
            return "FireWire"
        case kAudioDeviceTransportTypeDisplayPort:
            return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI:
            return "HDMI"
        case kAudioDeviceTransportTypeAVB:
            return "AVB"
        case kAudioDeviceTransportTypeThunderbolt:
            return "Thunderbolt"
        default:
            return "Other (\(transportType))"
        }
    }

    private func getBufferFrameSize(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var bufferSize: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &bufferSize
        )

        return status == noErr ? bufferSize : nil
    }

    /// Checks if a device is currently available using Apple's kAudioDevicePropertyDeviceIsAlive
    private func isDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isAlive
        )

        return status == noErr && isAlive == 1
    }
}

// MARK: - Error Types

enum CoreAudioRecorderError: LocalizedError {
    case audioUnitNotFound
    case audioUnitNotInitialized
    case deviceNotAvailable
    case invalidDeviceFormat(sampleRate: Double, channels: UInt32)
    case failedToCreateAudioUnit(status: OSStatus)
    case failedToEnableInput(status: OSStatus)
    case failedToDisableOutput(status: OSStatus)
    case failedToSetDevice(status: OSStatus)
    case failedToGetDeviceFormat(status: OSStatus)
    case failedToSetFormat(status: OSStatus)
    case failedToSetCallback(status: OSStatus)
    case failedToCreateFile(status: OSStatus)
    case failedToSetFileFormat(status: OSStatus)
    case failedToWriteFile(status: OSStatus)
    case failedToInitialize(status: OSStatus)
    case failedToStart(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .audioUnitNotFound:
            return "HAL Output AudioUnit not found"
        case .audioUnitNotInitialized:
            return "AudioUnit not initialized"
        case .deviceNotAvailable:
            return "Audio device is no longer available"
        case .invalidDeviceFormat(let sampleRate, let channels):
            return "Audio device reported invalid format (rate=\(sampleRate), channels=\(channels))"
        case .failedToCreateAudioUnit(let status):
            return "Failed to create AudioUnit: \(status)"
        case .failedToEnableInput(let status):
            return "Failed to enable input: \(status)"
        case .failedToDisableOutput(let status):
            return "Failed to disable output: \(status)"
        case .failedToSetDevice(let status):
            return "Failed to set input device: \(status)"
        case .failedToGetDeviceFormat(let status):
            return "Failed to get device format: \(status)"
        case .failedToSetFormat(let status):
            return "Failed to set audio format: \(status)"
        case .failedToSetCallback(let status):
            return "Failed to set input callback: \(status)"
        case .failedToCreateFile(let status):
            return "Failed to create audio file: \(status)"
        case .failedToSetFileFormat(let status):
            return "Failed to set file format: \(status)"
        case .failedToWriteFile(let status):
            return String(localized: "The microphone audio file could not be written (status \(status)).")
        case .failedToInitialize(let status):
            return "Failed to initialize AudioUnit: \(status)"
        case .failedToStart(let status):
            return "Failed to start AudioUnit: \(status)"
        }
    }
}
