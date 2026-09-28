import Testing
@testable import Zerm

/// The capture path's float-to-PCM conversion (#354 moved it out of CoreAudioRecorder).
struct AudioSampleConversionTests {

    private func mono(_ interleaved: [Float], channels: Int) -> [Float] {
        let frames = interleaved.count / channels
        var output = [Float](repeating: 0, count: frames)
        interleaved.withUnsafeBufferPointer { input in
            AudioSampleConversion.mixToMono(inputSamples: input.baseAddress!, frameCount: frames, channels: channels, output: &output)
        }
        return output
    }

    @Test func monoInputPassesThrough() {
        #expect(mono([0.1, -0.2, 0.3], channels: 1) == [0.1, -0.2, 0.3])
    }

    @Test func activeChannelsAreAveraged() {
        #expect(mono([0.2, 0.4, -0.2, -0.4], channels: 2) == [0.3, -0.3])
    }

    /// A silent channel (an unused input of a multichannel interface) must not halve the level.
    @Test func silentChannelsAreSkipped() {
        #expect(mono([0.5, 0, -0.5, 0], channels: 2) == [0.5, -0.5])
    }

    @Test func int16ConversionClipsAtFullScale() {
        #expect(AudioSampleConversion.floatToInt16(0) == 0)
        #expect(AudioSampleConversion.floatToInt16(1) == 32767)
        #expect(AudioSampleConversion.floatToInt16(2) == 32767)
        #expect(AudioSampleConversion.floatToInt16(-2) == -32768)
    }
}
