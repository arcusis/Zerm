import Foundation
import AVFoundation

/// Plays raw PCM produced by any `TTSProvider` through a single `AVAudioEngine` pipeline.
///
/// Supports streaming: chunks are enqueued as they are synthesized and play back-to-back,
/// so Read Aloud starts speaking the first sentence while the rest is still synthesizing.
final class TTSPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var currentSampleRate: Double = 0
    private var currentChannels: AVAudioChannelCount = 0
    private var meteringTapInstalled = false

    private var pendingBuffers = 0
    private var doneEnqueueing = false
    private var onPlaybackFinished: (() -> Void)?

    /// Output level (0...1) during playback, so the recorder widget can show live bars.
    var onLevel: ((Double) -> Void)?

    init() {
        engine.attach(playerNode)
    }

    /// Begins a new streaming session. `onFinished` fires (on the main queue) once every
    /// enqueued chunk has finished playing and `finishEnqueueing()` has been called.
    func startStreaming(onFinished: @escaping () -> Void) {
        stop()
        pendingBuffers = 0
        doneEnqueueing = false
        onPlaybackFinished = onFinished
    }

    /// Schedules one synthesized chunk; starts playback on the first chunk.
    func enqueue(_ audio: TTSAudio) throws {
        guard let buffer = try makeBuffer(audio) else { throw TTSError.emptyAudio }

        if !engine.isRunning { try engine.start() }
        installMeteringTapIfNeeded()

        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingBuffers -= 1
                self.checkFinished()
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    /// Signals no more chunks are coming; completion fires once the queue drains.
    func finishEnqueueing() {
        doneEnqueueing = true
        checkFinished()
    }

    func stop() {
        onPlaybackFinished = nil
        pendingBuffers = 0
        doneEnqueueing = false
        if playerNode.isPlaying {
            playerNode.stop()
        }
        emitSilence()
    }

    var isPlaying: Bool { playerNode.isPlaying }

    // MARK: - Private

    private func checkFinished() {
        guard doneEnqueueing, pendingBuffers <= 0 else { return }
        let callback = onPlaybackFinished
        onPlaybackFinished = nil
        emitSilence()
        callback?()
    }

    /// Builds a float PCM buffer from 16-bit LE PCM, (re)connecting the node if the format changed.
    private func makeBuffer(_ audio: TTSAudio) throws -> AVAudioPCMBuffer? {
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
            return nil
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
        return buffer
    }

    /// Installs the output-level tap exactly once and never removes it. Calling `removeTap`
    /// from the playback-completion handler (audio thread) while `stop()` also removes it
    /// (main thread) deadlocked AVAudioEngine and froze the app. The tap is cheap and gated
    /// on `isPlaying`.
    private func installMeteringTapIfNeeded() {
        guard !meteringTapInstalled else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, self.playerNode.isPlaying else { return }
            let level = TTSPlayer.rms(buffer)
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        meteringTapInstalled = true
    }

    private func emitSilence() {
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
