import AVFoundation
import AudioToolbox
import Foundation
import OSLog
import Atomics

/// Turns the tap's native output — typically 48 kHz stereo float — into the one shape the rest
/// of Zerm already speaks: 16 kHz mono 16-bit PCM.
///
/// That is deliberately the same format `CoreAudioRecorder` produces, so the microphone track,
/// the system track and the transcription feed all agree and nothing has to be converted twice.
/// It also keeps a long meeting small: 16 kHz mono is ~115 MB/hour against ~691 MB/hour for
/// 48 kHz stereo, and speech carries no information above the 8 kHz this preserves.
final class SystemAudioTrackWriter: SystemAudioRealtimeSink, @unchecked Sendable {

    enum WriterError: LocalizedError {
        case converterUnavailable
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return String(localized: "The system-audio converter could not be created after the output device changed.")
            case .conversionFailed:
                return String(localized: "System audio could not be converted for recording.")
            }
        }
    }

    struct ChunkTimestamp: Sendable {
        let hostTimeNanos: UInt64?
        let sampleTime: Double?
        let sourceSampleRate: Double
    }

    private struct RealtimeMetadata {
        var timestamp: ChunkTimestamp
        var droppedInputFrames: UInt64 = 0
    }

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "SystemAudioTrackWriter")

    /// Conversion and file IO happen off the Core Audio thread. `AVAudioFile.write` takes locks
    /// and can touch the filesystem, neither of which is safe to do in a render callback.
    private let queue = DispatchQueue(label: "com.arcusis.zerm.system-track-writer", qos: .userInitiated)

    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var sourceFormat: AVAudioFormat?

    /// 16 kHz mono Int16 little-endian, ready for `StreamingTranscriptionProvider.sendAudioChunk`.
    var onChunk: ((Data, ChunkTimestamp) -> Void)?
    var onError: ((Error) -> Void)?
    var onDroppedFrames: ((Int64, ChunkTimestamp) -> Void)?

    private(set) var framesWritten: AVAudioFramePosition = 0

    /// Capture accounting for #309. The call track came out at exactly half the meeting's
    /// duration and neither the frame count nor the sample-rate converter explains it — both
    /// were measured correct against the real tap. These are the numbers that will identify the
    /// missing half on the next real recording, written to the debug log on close.
    private var deliveryCount: Int = 0
    private var inputFramesSeen: Int64 = 0
    private var declaredSampleRate: Double = 0

    /// Uptime of the first delivery, the origin the written track is aligned against.
    private var firstDeliveryUptimeNanos: UInt64?
    /// Silence written to cover callback gaps, reported in the capture accounting.
    private var paddedFrames: Int64 = 0
    private var hostTimedDeliveries: Int = 0
    private var level: Float = 0
    private var sawSignal = false
    private var openedAtUptimeNanos = DispatchTime.now().uptimeNanoseconds
    private var lastDeliveryUptimeNanos: UInt64?
    private var lastSignalUptimeNanos: UInt64?
    private var reportedProcessingFailure = false
    private static let realtimeSlotCount: UInt64 = 32

    /// Headroom for the largest IO buffer the aggregate device is likely to hand over. This was
    /// 4096, which only ever fit because the frame count was being halved (#309); with the count
    /// correct, a large delivery would otherwise be dropped outright.
    static let realtimeBufferCapacity: AVAudioFrameCount = 16_384

    /// Callback jitter below this is not treated as a gap worth padding. 50 ms at 16 kHz.
    static let silenceToleranceFrames: AVAudioFrameCount = 800
    private let realtimeWriteIndex = ManagedAtomic<UInt64>(0)
    private let realtimeReadIndex = ManagedAtomic<UInt64>(0)
    private let realtimeRunning = ManagedAtomic<Bool>(false)
    private let realtimeDroppedFrames = ManagedAtomic<UInt64>(0)
    private let realtimeDropHostTimeNanos = ManagedAtomic<UInt64>(0)
    private let realtimeDropSampleTimeBits = ManagedAtomic<UInt64>(UInt64.max)
    private let realtimeSemaphore = DispatchSemaphore(value: 0)
    private let realtimeWorker = DispatchQueue(
        label: "com.arcusis.zerm.system-track-handoff",
        qos: .userInitiated
    )
    private var realtimeBuffers: [AVAudioPCMBuffer] = []
    private var realtimeMetadata = [RealtimeMetadata]()

    /// Most recent RMS level in dBFS, for the recording UI.
    var averagePowerDb: Float { queue.sync { level } }

    /// Whether any non-silent sample has ever arrived.
    ///
    /// This matters more than it looks. A process tap that has not been granted the
    /// `kTCCServiceAudioCapture` permission does not fail — every Core Audio call returns
    /// `noErr`, the IOProc fires at the right rate, and every sample is zero. Without this
    /// flag the feature would appear to work and quietly record an empty track.
    var hasCapturedSignal: Bool { queue.sync { sawSignal } }
    var secondsSinceLastDelivery: TimeInterval? {
        queue.sync { Self.elapsed(since: lastDeliveryUptimeNanos ?? openedAtUptimeNanos) }
    }
    var secondsSinceLastSignal: TimeInterval? {
        queue.sync { Self.elapsed(since: lastSignalUptimeNanos ?? openedAtUptimeNanos) }
    }

    // MARK: - Lifecycle

    func open(at url: URL) throws {
        try queue.sync {
            file = try AVAudioFile(
                forWriting: url,
                settings: Self.targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            framesWritten = 0
            deliveryCount = 0
            inputFramesSeen = 0
            firstDeliveryUptimeNanos = nil
            paddedFrames = 0
            hostTimedDeliveries = 0
            level = -160
            sawSignal = false
            openedAtUptimeNanos = DispatchTime.now().uptimeNanoseconds
            lastDeliveryUptimeNanos = nil
            lastSignalUptimeNanos = nil
            reportedProcessingFailure = false
        }
    }

    func close() {
        stopRealtimeInput()
        // A gap that runs to the end of the meeting produces no further callbacks, so the last
        // stretch of silence has to be filled here rather than on the next delivery.
        queue.sync {
            if let file { padSilenceIfCallbackGapped(in: file) }
        }
        reportCaptureAccounting()
        queue.sync {
            file = nil
            converter = nil
            sourceFormat = nil
        }
    }

    // MARK: - Ingest

    func prepareRealtimeInput(format: AVAudioFormat) {
        stopRealtimeInput()
        declaredSampleRate = format.sampleRate
        let capacity = Self.realtimeBufferCapacity
        let buffers = (0..<Int(Self.realtimeSlotCount)).compactMap { _ in
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        }
        guard buffers.count == Int(Self.realtimeSlotCount) else { return }
        realtimeBuffers = buffers
        realtimeMetadata = Array(
            repeating: .init(timestamp: .init(
                    hostTimeNanos: nil,
                    sampleTime: nil,
                    sourceSampleRate: format.sampleRate
                )),
            count: Int(Self.realtimeSlotCount)
        )
        realtimeWriteIndex.store(0, ordering: .relaxed)
        realtimeReadIndex.store(0, ordering: .relaxed)
        realtimeDroppedFrames.store(0, ordering: .relaxed)
        realtimeDropHostTimeNanos.store(0, ordering: .relaxed)
        realtimeDropSampleTimeBits.store(UInt64.max, ordering: .relaxed)
        realtimeRunning.store(true, ordering: .releasing)
        realtimeWorker.async { [weak self] in self?.runRealtimeInputWorker() }
    }

    /// Frames carried by one Core Audio delivery, counted from the buffer's OWN channel count
    /// rather than the whole-frame stride.
    ///
    /// `CATapDescription(stereoMixdownOfProcesses:)` is a two-channel tap, and Core Audio hands
    /// it over deinterleaved: one buffer per channel, each holding `frames * bytesPerSample`,
    /// while `mBytesPerFrame` covers both channels. Dividing the first buffer's byte count by
    /// `mBytesPerFrame` reported exactly half the frames on every callback — a 94-second meeting
    /// produced a 46.9-second call track whose clock anchors sat at a dead-constant 0.499 ratio,
    /// drifting further out of sync with the microphone every second.
    ///
    /// `mNumberChannels` is 1 per buffer when deinterleaved and the full count when interleaved,
    /// so this is correct for both layouts.
    static func frameCount(inFirstBuffer buffer: AudioBuffer, format: AVAudioFormat) -> Int {
        let bytesPerSample = max(1, Int(format.streamDescription.pointee.mBitsPerChannel / 8))
        let channels = max(1, Int(buffer.mNumberChannels))
        return Int(buffer.mDataByteSize) / (bytesPerSample * channels)
    }

    /// Realtime producer. Slots, PCM storage and metadata were allocated by `prepareRealtimeInput`.
    func enqueueRealtimeInput(
        _ input: UnsafePointer<AudioBufferList>,
        timestamp: AudioTimeStamp
    ) {
        guard realtimeRunning.load(ordering: .relaxed), !realtimeBuffers.isEmpty else { return }
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = source.first else { return }
        let format = realtimeBuffers[0].format
        let frames = Self.frameCount(inFirstBuffer: first, format: format)
        deliveryCount &+= 1
        inputFramesSeen &+= Int64(frames)
        guard frames > 0, frames <= Int(realtimeBuffers[0].frameCapacity) else {
            accumulateRealtimeDrop(frames: max(0, frames), timestamp: timestamp)
            realtimeSemaphore.signal()
            return
        }

        var write = realtimeWriteIndex.load(ordering: .relaxed)
        let read = realtimeReadIndex.load(ordering: .acquiring)
        guard write &- read < Self.realtimeSlotCount else {
            accumulateRealtimeDrop(frames: frames, timestamp: timestamp)
            realtimeSemaphore.signal()
            return
        }
        if realtimeDroppedFrames.load(ordering: .acquiring) > 0 {
            publishRealtimeDrop(at: write, sampleRate: format.sampleRate)
            write &+= 1
            guard write &- read < Self.realtimeSlotCount else {
                accumulateRealtimeDrop(frames: frames, timestamp: timestamp)
                realtimeSemaphore.signal()
                return
            }
        }
        let slot = Int(write % Self.realtimeSlotCount)
        let destinationBuffer = realtimeBuffers[slot]
        destinationBuffer.frameLength = destinationBuffer.frameCapacity
        let destination = UnsafeMutableAudioBufferListPointer(destinationBuffer.mutableAudioBufferList)
        guard source.count <= destination.count else {
            accumulateRealtimeDrop(frames: frames, timestamp: timestamp)
            realtimeSemaphore.signal()
            return
        }
        for index in source.indices {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else { continue }
            let byteCount = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(destinationData, sourceData, Int(byteCount))
            destination[index].mDataByteSize = byteCount
        }
        destinationBuffer.frameLength = AVAudioFrameCount(frames)
        realtimeMetadata[slot] = .init(
            timestamp: .init(
                hostTimeNanos: Self.hostTimeNanos(from: timestamp),
                sampleTime: Self.sampleTime(from: timestamp),
                sourceSampleRate: format.sampleRate
            )
        )
        realtimeWriteIndex.store(write &+ 1, ordering: .releasing)
        realtimeSemaphore.signal()
    }

    private func runRealtimeInputWorker() {
        while true {
            realtimeSemaphore.wait()
            while true {
                let read = realtimeReadIndex.load(ordering: .relaxed)
                let write = realtimeWriteIndex.load(ordering: .acquiring)
                guard read < write else { break }
                let slot = Int(read % Self.realtimeSlotCount)
                let buffer = realtimeBuffers[slot]
                let metadata = realtimeMetadata[slot]
                if metadata.droppedInputFrames > 0 {
                    reportRealtimeDrop(metadata)
                } else {
                    queue.sync { process(buffer, timestamp: metadata.timestamp) }
                }
                realtimeReadIndex.store(read &+ 1, ordering: .releasing)
            }
            if !realtimeRunning.load(ordering: .acquiring),
               realtimeReadIndex.load(ordering: .acquiring)
                    == realtimeWriteIndex.load(ordering: .acquiring) {
                reportPendingRealtimeDrop()
                return
            }
        }
    }

    private func accumulateRealtimeDrop(frames: Int, timestamp: AudioTimeStamp) {
        guard frames > 0 else { return }
        if realtimeDroppedFrames.load(ordering: .relaxed) == 0 {
            realtimeDropHostTimeNanos.store(
                Self.hostTimeNanos(from: timestamp) ?? 0,
                ordering: .relaxed
            )
            realtimeDropSampleTimeBits.store(
                Self.sampleTime(from: timestamp)?.bitPattern ?? UInt64.max,
                ordering: .relaxed
            )
        }
        realtimeDroppedFrames.wrappingIncrement(by: UInt64(frames), ordering: .releasing)
    }

    private func publishRealtimeDrop(at write: UInt64, sampleRate: Double) {
        let dropped = realtimeDroppedFrames.exchange(0, ordering: .acquiringAndReleasing)
        guard dropped > 0 else { return }
        let slot = Int(write % Self.realtimeSlotCount)
        let host = realtimeDropHostTimeNanos.exchange(0, ordering: .acquiringAndReleasing)
        let sampleBits = realtimeDropSampleTimeBits.exchange(UInt64.max, ordering: .acquiringAndReleasing)
        realtimeMetadata[slot] = .init(
            timestamp: .init(
                hostTimeNanos: host == 0 ? nil : host,
                sampleTime: sampleBits == UInt64.max ? nil : Double(bitPattern: sampleBits),
                sourceSampleRate: sampleRate
            ),
            droppedInputFrames: dropped
        )
        realtimeWriteIndex.store(write &+ 1, ordering: .releasing)
    }

    private func reportRealtimeDrop(_ metadata: RealtimeMetadata) {
        let sampleRate = metadata.timestamp.sourceSampleRate
        let outputFrames = Int64(
            (Double(metadata.droppedInputFrames) * Self.targetFormat.sampleRate
                / max(1, sampleRate)).rounded()
        )
        onDroppedFrames?(outputFrames, metadata.timestamp)
    }

    private func reportPendingRealtimeDrop() {
        let dropped = realtimeDroppedFrames.exchange(0, ordering: .acquiringAndReleasing)
        guard dropped > 0 else { return }
        let sampleRate = realtimeBuffers.first?.format.sampleRate ?? Self.targetFormat.sampleRate
        let host = realtimeDropHostTimeNanos.exchange(0, ordering: .acquiringAndReleasing)
        let sampleBits = realtimeDropSampleTimeBits.exchange(UInt64.max, ordering: .acquiringAndReleasing)
        reportRealtimeDrop(.init(
            timestamp: .init(
                hostTimeNanos: host == 0 ? nil : host,
                sampleTime: sampleBits == UInt64.max ? nil : Double(bitPattern: sampleBits),
                sourceSampleRate: sampleRate
            ),
            droppedInputFrames: dropped
        ))
    }

    /// Fills callback gaps with silence so the track's duration matches the meeting's.
    ///
    /// A process tap only fires while the captured app is actually emitting audio — measured at
    /// 10.5 deliveries/second against 91.6 for a whole-system tap, with the same 512 frames per
    /// delivery. Silence produces no callbacks at all, so writing only what arrives produced a
    /// *time-compressed* track: a 94-second meeting became a 46.9-second file that drifted
    /// further from the microphone every second, because the app happened to be audible about
    /// half the time. Gaps have to be real silence in the file, not missing samples.
    private func padSilenceIfCallbackGapped(in file: AVAudioFile) {
        // Deliberately a wall clock, not the delivery's own timestamp. The IOProc input time is
        // derived from the device sample clock, which simply stops while the tap is idle and
        // resumes where it left off — so it measures audio time, not elapsed time, and a gap is
        // invisible in it. Measured: with the app timestamp the shortfall never appeared at all.
        let now = DispatchTime.now().uptimeNanoseconds
        guard let origin = firstDeliveryUptimeNanos else {
            firstDeliveryUptimeNanos = now
            return
        }
        guard now > origin else { return }
        hostTimedDeliveries &+= 1

        let elapsed = Double(now &- origin) / 1_000_000_000
        let expected = AVAudioFramePosition((elapsed * Self.targetFormat.sampleRate).rounded())
        // Ordinary jitter between callbacks is not a gap. Only pad once the shortfall is large
        // enough to be audible drift.
        let shortfall = expected - framesWritten
        guard shortfall > Int64(Self.silenceToleranceFrames) else { return }

        var remaining = shortfall
        let chunk = AVAudioFrameCount(Self.targetFormat.sampleRate)   // 1s at a time
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(chunk), remaining))
            guard let silence = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: count) else { return }
            silence.frameLength = count
            if let channel = silence.int16ChannelData {
                memset(channel[0], 0, Int(count) * MemoryLayout<Int16>.size)
            }
            do {
                try file.write(from: silence)
            } catch {
                logger.error("Could not pad system-audio gap: \(error.localizedDescription, privacy: .public)")
                return
            }
            framesWritten += AVAudioFramePosition(count)
            paddedFrames += Int64(count)
            remaining -= Int64(count)
        }
    }

    /// Writes the ratio that identifies #309: how much audio reached the file per second of
    /// wall clock. A healthy capture is ~1.0; the reported meeting measured 0.499.
    private func reportCaptureAccounting() {
        guard deliveryCount > 0, openedAtUptimeNanos > 0 else { return }
        let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds &- openedAtUptimeNanos) / 1_000_000_000
        guard wallSeconds > 0.5 else { return }
        let writtenSeconds = Double(framesWritten) / Self.targetFormat.sampleRate
        let inputSeconds = declaredSampleRate > 0 ? Double(inputFramesSeen) / declaredSampleRate : 0
        let averageFrames = Double(inputFramesSeen) / Double(deliveryCount)
        let message = String(
            format: "system-audio capture: wall=%.2fs written=%.2fs input=%.2fs padded=%.2fs "
                + "ratio=%.3f deliveries=%d hostTimed=%d avgFrames=%.1f declaredRate=%.0f deliveriesPerSecond=%.1f",
            wallSeconds, writtenSeconds, inputSeconds,
            Double(paddedFrames) / Self.targetFormat.sampleRate,
            wallSeconds > 0 ? writtenSeconds / wallSeconds : 0,
            deliveryCount, hostTimedDeliveries, averageFrames, declaredSampleRate,
            Double(deliveryCount) / wallSeconds
        )
        logger.notice("\(message, privacy: .public)")
        DebugLogger.shared.log("SystemAudioTrackWriter", message)
    }

    private func stopRealtimeInput() {
        guard realtimeRunning.exchange(false, ordering: .acquiringAndReleasing) else {
            realtimeBuffers = []
            realtimeMetadata = []
            return
        }
        realtimeSemaphore.signal()
        realtimeWorker.sync {}
        realtimeBuffers = []
        realtimeMetadata = []
    }

    private static func hostTimeNanos(from timestamp: AudioTimeStamp) -> UInt64? {
        guard timestamp.mFlags.contains(.hostTimeValid) else { return nil }
        return AudioConvertHostTimeToNanos(timestamp.mHostTime)
    }

    private static func sampleTime(from timestamp: AudioTimeStamp) -> Double? {
        timestamp.mFlags.contains(.sampleTimeValid) ? timestamp.mSampleTime : nil
    }

    private func process(_ buffer: AVAudioPCMBuffer, timestamp: ChunkTimestamp) {
        guard let file else { return }
        lastDeliveryUptimeNanos = DispatchTime.now().uptimeNanoseconds

        if converter == nil || sourceFormat != buffer.format {
            // The default output device can change mid-meeting — headphones in, AirPlay out —
            // and the tap format follows it. Rebuild rather than write garbage.
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            sourceFormat = buffer.format
            if converter == nil {
                logger.error("No converter from \(buffer.format, privacy: .public) to 16 kHz mono")
                reportProcessingFailure(.converterUnavailable)
                return
            }
        }
        guard let converter else { return }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            reportProcessingFailure(.conversionFailed)
            return
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0 else {
            if let conversionError {
                logger.error("System audio conversion failed: \(conversionError.localizedDescription, privacy: .public)")
            }
            reportProcessingFailure(.conversionFailed)
            return
        }

        padSilenceIfCallbackGapped(in: file)

        do {
            try file.write(from: output)
            framesWritten += AVAudioFramePosition(output.frameLength)
        } catch {
            logger.error("System audio write failed: \(error.localizedDescription, privacy: .public)")
            onError?(error)
            return
        }

        level = Self.rmsDb(of: output)
        if level > -120 {
            sawSignal = true
            lastSignalUptimeNanos = DispatchTime.now().uptimeNanoseconds
        }

        if let onChunk, let data = Self.data(from: output) {
            onChunk(data, timestamp)
        }
    }

    private func reportProcessingFailure(_ error: WriterError) {
        guard !reportedProcessingFailure else { return }
        reportedProcessingFailure = true
        onError?(error)
    }

    // MARK: - Helpers

    private static func data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    private static func rmsDb(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData, buffer.frameLength > 0 else { return -160 }
        var sum: Double = 0
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Double(channel[0][frame]) / Double(Int16.max)
            sum += sample * sample
        }
        let rms = (sum / Double(buffer.frameLength)).squareRoot()
        return rms > 0 ? Float(20 * log10(rms)) : -160
    }

    private static func elapsed(since uptimeNanos: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= uptimeNanos else { return 0 }
        return Double(now - uptimeNanos) / 1_000_000_000
    }
}
