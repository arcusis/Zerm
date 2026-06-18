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
    private var tapInstalled = false

    /// Output level (0...1) during playback, so the recorder widget can show live bars.
    var onLevel: ((Double) -> Void)?

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

        installMeteringTap()

        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            self?.teardownMeteringTap()
            DispatchQueue.main.async { onFinished() }
        }
        playerNode.play()
    }

    func stop() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        teardownMeteringTap()
    }

    var isPlaying: Bool { playerNode.isPlaying }

    // MARK: - Output level metering (drives the widget's audio bars)

    private func installMeteringTap() {
        guard !tapInstalled else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let level = TTSPlayer.rms(buffer)
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        tapInstalled = true
    }

    private func teardownMeteringTap() {
        guard tapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        tapInstalled = false
        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let ch0 = data[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = ch0[i]
            sum += s * s
        }
        let rms = (sum / Float(frames)).squareRoot()
        return Double(min(1.0, rms * 3.5)) // gain for visual punch
    }
}
