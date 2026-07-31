import AVFoundation
import Foundation
import OSLog

/// Turns the tap's native output — typically 48 kHz stereo float — into the one shape the rest
/// of Zerm already speaks: 16 kHz mono 16-bit PCM.
///
/// That is deliberately the same format `CoreAudioRecorder` produces, so the microphone track,
/// the system track and the transcription feed all agree and nothing has to be converted twice.
/// It also keeps a long meeting small: 16 kHz mono is ~115 MB/hour against ~691 MB/hour for
/// 48 kHz stereo, and speech carries no information above the 8 kHz this preserves.
final class SystemAudioTrackWriter: @unchecked Sendable {

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
    var onChunk: ((Data) -> Void)?

    private(set) var framesWritten: AVAudioFramePosition = 0
    private var level: Float = 0
    private var sawSignal = false

    /// Most recent RMS level in dBFS, for the recording UI.
    var averagePowerDb: Float { queue.sync { level } }

    /// Whether any non-silent sample has ever arrived.
    ///
    /// This matters more than it looks. A process tap that has not been granted the
    /// `kTCCServiceAudioCapture` permission does not fail — every Core Audio call returns
    /// `noErr`, the IOProc fires at the right rate, and every sample is zero. Without this
    /// flag the feature would appear to work and quietly record an empty track.
    var hasCapturedSignal: Bool { queue.sync { sawSignal } }

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
        }
    }

    func close() {
        queue.sync {
            file = nil
            converter = nil
            sourceFormat = nil
        }
    }

    // MARK: - Ingest

    /// Called from the tap's realtime thread. The buffer it hands over is only valid for the
    /// duration of the call, so it is copied before anything is deferred.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [weak self] in
            self?.process(copy)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }

        if converter == nil || sourceFormat != buffer.format {
            // The default output device can change mid-meeting — headphones in, AirPlay out —
            // and the tap format follows it. Rebuild rather than write garbage.
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            sourceFormat = buffer.format
            if converter == nil {
                logger.error("No converter from \(buffer.format, privacy: .public) to 16 kHz mono")
                return
            }
        }
        guard let converter else { return }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

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
            return
        }

        do {
            try file.write(from: output)
            framesWritten += AVAudioFramePosition(output.frameLength)
        } catch {
            logger.error("System audio write failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        level = Self.rmsDb(of: output)
        if level > -120 { sawSignal = true }

        if let onChunk, let data = Self.data(from: output) {
            onChunk(data)
        }
    }

    // MARK: - Helpers

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let source = buffer.audioBufferList.pointee
        let destination = copy.mutableAudioBufferList.pointee
        let count = min(Int(source.mNumberBuffers), Int(destination.mNumberBuffers))
        for index in 0..<count {
            let sourceBuffer = Self.buffer(at: index, in: buffer.audioBufferList)
            let destinationBuffer = Self.buffer(at: index, in: copy.mutableAudioBufferList)
            guard let src = sourceBuffer.mData, let dst = destinationBuffer.mData else { continue }
            memcpy(dst, src, Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)))
        }
        return copy
    }

    private static func buffer(at index: Int, in list: UnsafePointer<AudioBufferList>) -> AudioBuffer {
        UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))[index]
    }

    private static func buffer(at index: Int, in list: UnsafeMutablePointer<AudioBufferList>) -> AudioBuffer {
        UnsafeMutableAudioBufferListPointer(list)[index]
    }

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
}
