import AVFoundation
import Testing
@testable import Zerm

/// Regression cover for #309: the meeting call track was written at exactly half rate.
///
/// `enqueueRealtimeInput` counted frames from the first buffer's byte size divided by
/// `mBytesPerFrame`. For a deinterleaved stereo tap — which is what
/// `CATapDescription(stereoMixdownOfProcesses:)` produces — the list holds one buffer per
/// channel of `frames * bytesPerSample`, while `mBytesPerFrame` covers both channels. Every
/// callback therefore reported half the frames, so a 94-second meeting produced a 46.9-second
/// call track that drifted a full 47 seconds out of sync with the microphone.
struct SystemAudioFrameCountTests {

    private func format(
        _ common: AVAudioCommonFormat,
        rate: Double,
        channels: AVAudioChannelCount,
        interleaved: Bool
    ) -> AVAudioFormat {
        AVAudioFormat(commonFormat: common, sampleRate: rate, channels: channels, interleaved: interleaved)!
    }

    private func buffer(bytes: Int, channels: UInt32) -> AudioBuffer {
        AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(bytes), mData: nil)
    }

    /// The exact shape that shipped broken: 2-channel float32 tap, deinterleaved.
    @Test func deinterleavedStereoTapCountsWholeFramesNotHalf() {
        let tap = format(.pcmFormatFloat32, rate: 48_000, channels: 2, interleaved: false)
        // One buffer per channel: 1024 frames x 4 bytes.
        let first = buffer(bytes: 1024 * 4, channels: 1)
        #expect(SystemAudioTrackWriter.frameCount(inFirstBuffer: first, format: tap) == 1024)
    }

    @Test func interleavedStereoTapCountsWholeFrames() {
        let tap = format(.pcmFormatFloat32, rate: 48_000, channels: 2, interleaved: true)
        // Single buffer carrying both channels: 1024 frames x 2 ch x 4 bytes.
        let first = buffer(bytes: 1024 * 2 * 4, channels: 2)
        #expect(SystemAudioTrackWriter.frameCount(inFirstBuffer: first, format: tap) == 1024)
    }

    @Test func monoTapCountsWholeFrames() {
        let tap = format(.pcmFormatFloat32, rate: 48_000, channels: 1, interleaved: true)
        let first = buffer(bytes: 1024 * 4, channels: 1)
        #expect(SystemAudioTrackWriter.frameCount(inFirstBuffer: first, format: tap) == 1024)
    }

    @Test func int16TapCountsWholeFrames() {
        let tap = format(.pcmFormatInt16, rate: 44_100, channels: 2, interleaved: false)
        let first = buffer(bytes: 512 * 2, channels: 1)
        #expect(SystemAudioTrackWriter.frameCount(inFirstBuffer: first, format: tap) == 512)
    }

    /// The defect as a duration assertion, which is how it actually presented.
    @Test func aFullMeetingOfDeliveriesYieldsAFullLengthTrack() {
        let tap = format(.pcmFormatFloat32, rate: 48_000, channels: 2, interleaved: false)
        let framesPerDelivery = 1024
        let meetingSeconds = 94.0
        let deliveries = Int((48_000 * meetingSeconds / Double(framesPerDelivery)).rounded())

        let first = buffer(bytes: framesPerDelivery * 4, channels: 1)
        let counted = (0..<deliveries).reduce(0) { total, _ in
            total + SystemAudioTrackWriter.frameCount(inFirstBuffer: first, format: tap)
        }

        let capturedSeconds = Double(counted) / 48_000
        // The broken math produced 0.499 of the real duration; anything below 0.99 is that bug.
        #expect(capturedSeconds / meetingSeconds > 0.99)
    }

    @Test func theRingBufferCanHoldARealisticIOBuffer() {
        // With the count corrected, a delivery larger than the old 4096-frame capacity would be
        // dropped outright rather than silently half-written.
        #expect(SystemAudioTrackWriter.realtimeBufferCapacity >= 8192)
    }
}
