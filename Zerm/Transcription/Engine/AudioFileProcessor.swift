import Foundation
import AVFoundation
import os

class AudioProcessor {
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "AudioProcessor")
    
    struct AudioFormat {
        static let targetSampleRate: Double = 16000.0
        static let targetChannels: UInt32 = 1
        static let targetBitDepth: UInt32 = 16
    }
    
    enum AudioProcessingError: LocalizedError {
        case invalidAudioFile
        case conversionFailed
        case exportFailed
        case unsupportedFormat
        case sampleExtractionFailed
        
        var errorDescription: String? {
            switch self {
            case .invalidAudioFile:
                return "The audio file is invalid or corrupted"
            case .conversionFailed:
                return "Failed to convert the audio format"
            case .exportFailed:
                return "Failed to export the processed audio"
            case .unsupportedFormat:
                return "The audio format is not supported"
            case .sampleExtractionFailed:
                return "Failed to extract audio samples"
            }
        }
    }
    
    func processAudioToSamples(_ url: URL) async throws -> [Float] {
        do {
            return try readUsingAudioFile(url)
        } catch {
            // AVAudioFile rejects container/codec combinations the rest of the media
            // stack plays fine — notably avfaudio error -50 on Teams mp4/m4a meeting
            // recordings. AVAssetReader decodes those, and hands back target-format
            // LPCM directly, skipping the manual seek-and-convert loop above.
            logger.warning("AVAudioFile pipeline failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to AVAssetReader.")
            return try await readUsingAssetReader(url)
        }
    }

    private func readUsingAudioFile(_ url: URL) throws -> [Float] {
        guard let audioFile = try? AVAudioFile(forReading: url) else {
            throw AudioProcessingError.invalidAudioFile
        }

        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let channels = format.channelCount
        let totalFrames = audioFile.length
        
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.targetSampleRate,
            channels: AudioFormat.targetChannels,
            interleaved: false
        )
        
        guard let outputFormat = outputFormat else {
            throw AudioProcessingError.unsupportedFormat
        }
        
        let chunkSize: AVAudioFrameCount = 50_000_000
        var allSamples: [Float] = []
        var currentFrame: AVAudioFramePosition = 0
        
        while currentFrame < totalFrames {
            let remainingFrames = totalFrames - currentFrame
            let framesToRead = min(chunkSize, AVAudioFrameCount(remainingFrames))
            
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw AudioProcessingError.conversionFailed
            }
            
            audioFile.framePosition = currentFrame
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)
            
            if sampleRate == AudioFormat.targetSampleRate && channels == AudioFormat.targetChannels {
                let chunkSamples = convertToWhisperFormat(inputBuffer)
                allSamples.append(contentsOf: chunkSamples)
            } else {
                guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
                    throw AudioProcessingError.conversionFailed
                }
                
                let ratio = AudioFormat.targetSampleRate / sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
                
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
                    throw AudioProcessingError.conversionFailed
                }
                
                var error: NSError?
                let status = converter.convert(
                    to: outputBuffer,
                    error: &error,
                    withInputFrom: { inNumPackets, outStatus in
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                )
                
                if error != nil {
                    throw AudioProcessingError.conversionFailed
                }
                
                if status == .error {
                    throw AudioProcessingError.conversionFailed
                }
                
                let chunkSamples = convertToWhisperFormat(outputBuffer)
                allSamples.append(contentsOf: chunkSamples)
            }
            
            currentFrame += AVAudioFramePosition(framesToRead)
        }
        
        return allSamples
    }

    /// Resilient fallback decoder for media containers `AVAudioFile` cannot open.
    /// Requests 16 kHz mono Float32 LPCM straight from the reader, so no manual
    /// resampling or channel mixing is needed.
    private func readUsingAssetReader(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        // Use the primary audio track only, matching the AVAudioFile path — mixing
        // multiple tracks would change what the user gets back for the same file.
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioProcessingError.invalidAudioFile
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioFormat.targetSampleRate,
                AVNumberOfChannelsKey: AudioFormat.targetChannels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw AudioProcessingError.conversionFailed
        }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? AudioProcessingError.sampleExtractionFailed
        }

        var samples: [Float] = []
        do {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                try validateAssetReaderOutputFormat(sampleBuffer)

                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                guard byteCount >= MemoryLayout<Float>.size else { continue }

                var chunk = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
                let status = chunk.withUnsafeMutableBytes { destination -> OSStatus in
                    guard let baseAddress = destination.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                    return CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: destination.count,
                        destination: baseAddress
                    )
                }
                guard status == kCMBlockBufferNoErr else {
                    throw AudioProcessingError.sampleExtractionFailed
                }
                samples.append(contentsOf: chunk)
            }
        } catch {
            reader.cancelReading()
            throw error
        }

        if reader.status == .failed {
            throw reader.error ?? AudioProcessingError.sampleExtractionFailed
        }
        if reader.status == .cancelled {
            throw CancellationError()
        }
        guard !samples.isEmpty else {
            throw AudioProcessingError.sampleExtractionFailed
        }

        // Deliberately NOT peak-normalized. Both decoders hand back Float32 LPCM
        // already scaled to [-1, 1], and the AVAudioFile path does no normalizing —
        // dividing by the peak here would make the same file transcribe at a
        // different gain depending on which decoder happened to open it.
        return samples
    }

    /// The reader is asked for a specific LPCM layout, but the decoder is free to
    /// disagree — validate before reinterpreting the bytes as `Float`.
    private func validateAssetReaderOutputFormat(_ sampleBuffer: CMSampleBuffer) throws {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw AudioProcessingError.conversionFailed
        }

        let format = streamDescription.pointee
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        guard
            format.mFormatID == kAudioFormatLinearPCM,
            abs(format.mSampleRate - AudioFormat.targetSampleRate) < 1.0,
            format.mChannelsPerFrame == AudioFormat.targetChannels,
            format.mBitsPerChannel == 32,
            isFloat,
            !isBigEndian,
            // Interleaving only changes byte layout for multi-channel audio; mono is
            // identical either way, so don't reject the flag we cannot test up front.
            format.mChannelsPerFrame == 1 || !isNonInterleaved
        else {
            throw AudioProcessingError.conversionFailed
        }
    }

    private func convertToWhisperFormat(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }
        
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else {
            return []
        }

        var samples = Array(repeating: Float(0), count: frameLength)
        
        if channelCount == 1 {
            let monoChannel = channelData[0]
            samples = Array(UnsafeBufferPointer(start: monoChannel, count: frameLength))
        } else {
            for frame in 0..<frameLength {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    let channelSamples = channelData[channel]
                    sum += channelSamples[frame]
                }
                samples[frame] = sum / Float(channelCount)
            }
        }
        
        let maxSample = samples.map(abs).max() ?? 1
        if maxSample > 0 {
            samples = samples.map { $0 / maxSample }
        }
        
        return samples
    }
    func saveSamplesAsWav(samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else {
            throw AudioProcessingError.sampleExtractionFailed
        }

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFormat.targetSampleRate,
            channels: AudioFormat.targetChannels,
            interleaved: true
        )

        guard let outputFormat = outputFormat else {
            throw AudioProcessingError.unsupportedFormat
        }

        let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        )
        
        guard let buffer = buffer else {
            throw AudioProcessingError.conversionFailed
        }
        
        // Convert float samples to int16
        let int16Samples = samples.map { max(-1.0, min(1.0, $0)) * Float(Int16.max) }.map { Int16($0) }

        // Copy samples to buffer
        guard let channelData = buffer.int16ChannelData else {
            throw AudioProcessingError.conversionFailed
        }
        // Guard the channel-count before subscript access — a zero-channel buffer
        // would crash here. (VoiceInk #394)
        guard buffer.format.channelCount > 0 else {
            throw AudioProcessingError.conversionFailed
        }
        let firstChannel = channelData[0]

        int16Samples.withUnsafeBufferPointer { int16Buffer in
            guard let int16Pointer = int16Buffer.baseAddress else { return }
            firstChannel.update(from: int16Pointer, count: int16Samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Create audio file
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        try audioFile.write(from: buffer)
    }
} 
