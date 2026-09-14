@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Converts any file AVFoundation can decode — audio, or the audio track of a video — into the
/// 16 kHz mono Int16 WAV that Zerm's transcription and diarization paths consume.
enum AudioFileConverter {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    static let supportedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "mp4", "mov", "m4v", "flac", "ogg", "opus", "aac", "caf", "aiff", "aif", "amr", "3gp"
    ]

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

    /// Whether the file looks like audio or video Zerm can try to decode.
    static func isSupported(_ url: URL) -> Bool {
        if supportedExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    /// Writes `source` to `destination` in `targetFormat` and returns the duration in seconds.
    /// Streams through the file rather than loading it whole, so a two-hour recording does not
    /// have to fit in memory. Checks for cancellation between chunks.
    @discardableResult
    static func convert(_ source: URL, to destination: URL) async throws -> TimeInterval {
        do {
            return try convertWithAudioFile(source, to: destination)
        } catch let error as ConversionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // AVAudioFile cannot open video containers or some mp4/m4a codec combinations that
            // the rest of the media stack plays fine. AVAssetReader decodes those.
            try? FileManager.default.removeItem(at: destination)
            return try await convertWithAssetReader(source, to: destination)
        }
    }

    private static func convertWithAudioFile(_ source: URL, to destination: URL) throws -> TimeInterval {
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
            try Task.checkCancellation()
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

    /// Decodes the first audio track straight to the target format, one sample buffer at a time.
    private static func convertWithAssetReader(_ source: URL, to destination: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ConversionError.unreadable(source.lastPathComponent)
        }
        guard let track = tracks.first else { throw ConversionError.emptyAudio }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ConversionError.unreadable(source.lastPathComponent)
        }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else { throw ConversionError.unreadable(source.lastPathComponent) }
        reader.add(trackOutput)
        guard reader.startReading() else { throw ConversionError.unreadable(source.lastPathComponent) }

        var framesWritten: AVAudioFramePosition = 0
        do {
            // Scoped so the writer is released, and the WAV header finalised, before returning.
            try {
                let output = try AVAudioFile(
                    forWriting: destination,
                    settings: targetFormat.settings,
                    commonFormat: .pcmFormatInt16,
                    interleaved: true
                )
                while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
                    guard frames > 0,
                          let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frames),
                          let channel = buffer.int16ChannelData?[0],
                          let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                    let byteCount = min(CMBlockBufferGetDataLength(blockBuffer), Int(frames) * MemoryLayout<Int16>.size)
                    guard CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: byteCount,
                        destination: UnsafeMutableRawPointer(channel)
                    ) == kCMBlockBufferNoErr else {
                        throw ConversionError.unreadable(source.lastPathComponent)
                    }
                    buffer.frameLength = AVAudioFrameCount(byteCount / MemoryLayout<Int16>.size)
                    try output.write(from: buffer)
                    framesWritten += AVAudioFramePosition(buffer.frameLength)
                }
            }()
        } catch {
            reader.cancelReading()
            throw error
        }

        guard reader.status == .completed else { throw ConversionError.unreadable(source.lastPathComponent) }
        guard framesWritten > 0 else { throw ConversionError.emptyAudio }
        return Double(framesWritten) / targetFormat.sampleRate
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
