/// Converts captured float samples to the mono 16-bit PCM Zerm writes to disk.
enum AudioSampleConversion {
    /// Mix multi-channel float samples to mono, skipping near-silent channels.
    static func mixToMono(
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

    @inline(__always)
    static func floatToInt16(_ sample: Float32) -> Int16 {
        let scaled = sample * 32767.0
        let clipped = max(-32768.0, min(32767.0, scaled))
        return Int16(clipped)
    }
}
