import AVFoundation
import Testing
@testable import Zerm

/// Layout-independence cover for the tap frame count.
///
/// This is **not** a fix for #309. That defect — the call track written at exactly half the
/// meeting's duration — was originally diagnosed here and the diagnosis was wrong. Probing the
/// real Core Audio tap shows it delivers a single interleaved buffer (`mNumberBuffers=1`,
/// `mNumberChannels=2`, `mBytesPerFrame=8`), for which the previous `bytes / mBytesPerFrame`
/// and the current `bytes / (bytesPerSample * mNumberChannels)` agree exactly. Both return 512
/// for a real 512-frame delivery.
///
/// The counting is kept because it is correct for any layout rather than only the one this Mac
/// happens to report, and a tap that ever hands over deinterleaved buffers would silently halve
/// under the old form. The real cause of #309 is still open; `SystemAudioTrackWriter` now logs
/// the capture accounting needed to identify it from a real recording.
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

    /// A deinterleaved 2-channel tap, where the two formulas would disagree.
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

    /// Duration accounting for a deinterleaved tap. Note this does not reproduce #309: the
    /// real tap on this platform is interleaved, where the old formula was already correct.
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
        #expect(capturedSeconds / meetingSeconds > 0.99)
    }

    /// The observed tap delivers 512 frames per callback, but the ring slot must survive a much
    /// larger IO buffer: anything above capacity is dropped outright, not truncated.
    @Test func theRingBufferCanHoldARealisticIOBuffer() {
        #expect(SystemAudioTrackWriter.realtimeBufferCapacity >= 8192)
    }

    /// Pins the layout the real tap reports, so a future platform change that breaks the
    /// assumption shows up here rather than as silently halved audio.
    @Test func theInterleavedTapLayoutAgreesWithBothFormulas() {
        let tap = format(.pcmFormatFloat32, rate: 48_000, channels: 2, interleaved: true)
        let first = buffer(bytes: 4096, channels: 2)   // exactly what the probe observed
        let declaredBytesPerFrame = Int(tap.streamDescription.pointee.mBytesPerFrame)
        #expect(declaredBytesPerFrame == 8)
        #expect(4096 / declaredBytesPerFrame == 512)
        #expect(SystemAudioTrackWriter.frameCount(inFirstBuffer: first, format: tap) == 512)
    }
}
