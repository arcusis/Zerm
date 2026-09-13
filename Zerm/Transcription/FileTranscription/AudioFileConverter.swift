@preconcurrency import AVFoundation
import Foundation

/// Converts any file AVFoundation can decode into the 16 kHz mono Int16 WAV that Zerm's
/// transcription and diarization paths consume.
enum AudioFileConverter {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    static let supportedExtensions = ["wav", "mp3", "m4a", "mp4", "flac", "ogg", "aac", "caf", "aiff"]

    enum ConversionError: LocalizedError {
        case unreadable(String)
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                let format = String(localized: "Could not read audio from %@.")
                return String.localizedStringWithFormat(format, name)
            case .emptyAudio:
                return String(localized: "That file contains no audio.")
            }
        }
    }

    /// Writes `source` to `destination` in `targetFormat` and returns the source duration in
    /// seconds. Streams through the file rather than loading it whole, so a two-hour recording
    /// does not have to fit in memory.
    @discardableResult
    static func convert(_ source: URL, to destination: URL) throws -> TimeInterval {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0 else { throw ConversionError.emptyAudio }

        let output = try AVAudioFile(
            forWriting: destination,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard let converter = AVAudioConverter(from: input.processingFormat, to: targetFormat) else {
            throw ConversionError.unreadable(source.lastPathComponent)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let chunkFrames: AVAudioFrameCount = 16_384
        let ratio = targetFormat.sampleRate / input.processingFormat.sampleRate

        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunkFrames) else { break }
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }

            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { break }

            var error: NSError?
            // The input block is called synchronously by `convert`, so a nonisolated box is
            // enough to hand the buffer across without it being captured as shared state.
            let pending = ConversionInput(buffer: buffer)
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                guard let next = pending.take() else { outStatus.pointee = .noDataNow; return nil }
                outStatus.pointee = .haveData
                return next
            }
            guard status != .error, converted.frameLength > 0 else { continue }
            try output.write(from: converted)
        }
        return Double(input.length) / input.fileFormat.sampleRate
    }

    /// One-shot holder for a buffer handed to `AVAudioConverter`'s pull block.
    private final class ConversionInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}
