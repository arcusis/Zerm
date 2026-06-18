import Foundation
import AVFoundation

/// Plays raw PCM produced by any `TTSProvider` through a single `AVAudioEngine` pipeline.
///
/// v1 plays a fully-synthesized buffer (read-aloud is batch by nature). The engine
/// keeps a player node attached and reconnects when the sample rate changes.
final class TTSPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var attached = false
    private var currentSampleRate: Double = 0
    private var currentChannels: AVAudioChannelCount = 0

    init() {
        engine.attach(playerNode)
        attached = true
    }

    /// Plays `audio`, calling `onFinished` on the main queue when playback completes
    /// (not called if interrupted by `stop()` or a new `play`).
    func play(_ audio: TTSAudio, onFinished: @escaping () -> Void) throws {
        stop()

        let channels = AVAudioChannelCount(max(1, audio.channels))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: audio.sampleRate,
                                         channels: channels,
                                         interleaved: false) else {
            throw TTSError.badResponse
        }

        let bytesPerSample = 2 // 16-bit
        let frameCount = audio.pcm.count / (bytesPerSample * Int(channels))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw TTSError.emptyAudio
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        audio.pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard let channelData = buffer.floatChannelData else { return }
            let ch = Int(channels)
            for frame in 0..<frameCount {
                for c in 0..<ch {
                    let s = Int16(littleEndian: samples[frame * ch + c])
                    channelData[c][frame] = Float(s) / 32768.0
                }
            }
        }

        if currentSampleRate != audio.sampleRate || currentChannels != channels {
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            currentSampleRate = audio.sampleRate
            currentChannels = channels
        }

        if !engine.isRunning {
            try engine.start()
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: []) {
            DispatchQueue.main.async { onFinished() }
        }
        playerNode.play()
    }

    func stop() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
    }

    var isPlaying: Bool { playerNode.isPlaying }
}
