import AVFoundation
import Foundation
import Testing
@testable import Zerm

/// The reusable long-file pieces: format conversion, windowed transcription with overlap
/// reconciliation, and word-to-speaker attribution. No models, hardware or network.
struct FileTranscriptionTests {

    // MARK: - Overlap reconciliation

    @Test func overlappingWordsAreNotDuplicated() {
        let result = WindowedFileTranscriber.reconcile(
            previous: "we should ship the new recording system tomorrow",
            next: "recording system tomorrow after the final review"
        )
        #expect(result == "after the final review")
    }

    @Test func fuzzyOverlapReconciliationTrimsProviderWordVariation() {
        let result = WindowedFileTranscriber.reconcileResult(
            previous: "we reviewed the recording system today",
            next: "recording systems today and approved it"
        )
        #expect(result.text == "and approved it")
        #expect(result.droppedPrefixWords == 3)
    }

    @Test func overlapReconciliationHandlesHebrewAndPunctuation() {
        let suffix = WindowedFileTranscriber.reconcile(
            previous: "אנחנו משיקים את מערכת ההקלטה החדשה מחר.",
            next: "מערכת ההקלטה החדשה מחר ואז נבדוק אותה"
        )
        #expect(suffix == "ואז נבדוק אותה")
    }

    @Test func unrelatedConsecutiveWindowsArePreserved() {
        let suffix = WindowedFileTranscriber.reconcile(
            previous: "first agenda item",
            next: "completely different sentence"
        )
        #expect(suffix == "completely different sentence")
    }

    // MARK: - Windowed transcription

    /// 70 s at 30 s windows with 2 s overlap gives windows at 0, 28 and 56 s. The second window's
    /// repeated words are dropped and its start advances past the overlap; the failing third
    /// window becomes a gap without discarding the transcript already produced.
    @Test func windowsReconcileOverlapAndReportFailedWindowsAsGaps() async throws {
        let url = try Self.silentWAV(seconds: 70)
        defer { try? FileManager.default.removeItem(at: url) }

        let calls = CallCounter()
        let transcriber = WindowedFileTranscriber { _ in
            switch await calls.next() {
            case 0: return "alpha beta gamma delta"
            case 1: return "gamma delta epsilon"
            default: throw URLError(.timedOut)
            }
        }

        let transcript = try await transcriber.transcribeFile(url)

        #expect(await calls.count == 3)
        #expect(transcript.segments.map(\.text) == ["alpha beta gamma delta", "epsilon"])
        #expect(transcript.segments[0].start == 0)
        #expect(transcript.segments[0].end == 30)
        #expect(transcript.segments[1].start == 30)
        #expect(transcript.segments[1].end == 58)
        #expect(transcript.gaps.count == 1)
        #expect(transcript.gaps.first?.start == 56)
        #expect(transcript.gaps.first?.end == 70)
    }

    @Test func emptyFileProducesNoWindows() async throws {
        let url = try Self.silentWAV(seconds: 0)
        defer { try? FileManager.default.removeItem(at: url) }

        let calls = CallCounter()
        let transcriber = WindowedFileTranscriber { _ in
            _ = await calls.next()
            return "unexpected"
        }

        let transcript = try await transcriber.transcribeFile(url)

        #expect(transcript.segments.isEmpty)
        #expect(await calls.count == 0)
    }

    // MARK: - Speaker attribution

    @Test func estimatedSpeakerSplitsPreserveEveryTranscriptWordExactlyOnce() {
        let segment = TranscriptSegment(start: 0, end: 4, text: "one two three four five six")
        let turns = [
            SpeakerTurn(speakerIndex: 0, start: 0, end: 2),
            SpeakerTurn(speakerIndex: 1, start: 2, end: 4)
        ]

        let attributed = SpeakerAttributor.split([segment], using: turns)

        #expect(attributed.map(\.text).joined(separator: " ") == segment.text)
        #expect(attributed.map(\.speakerIndex) == [0, 1])
        #expect(attributed.allSatisfy { $0.speakerConfidence == .estimatedFromWindow })
    }

    @Test func singleOverlappingSpeakerKeepsTheSegmentWhole() {
        let segment = TranscriptSegment(start: 10, end: 20, text: "hello there")
        let attributed = SpeakerAttributor.split(
            [segment],
            using: [SpeakerTurn(speakerIndex: 2, start: 8, end: 25)]
        )

        #expect(attributed.count == 1)
        #expect(attributed[0].id == segment.id)
        #expect(attributed[0].text == "hello there")
        #expect(attributed[0].speakerIndex == 2)
    }

    @Test func nonOverlappingTurnsAttributeToNobody() {
        let segment = TranscriptSegment(start: 100, end: 110, text: "hello")
        let attributed = SpeakerAttributor.split(
            [segment],
            using: [SpeakerTurn(speakerIndex: 0, start: 0, end: 5)]
        )

        #expect(attributed == [segment])
        #expect(attributed[0].speakerIndex == nil)
    }

    // MARK: - Conversion

    @Test func conversionProducesSixteenKilohertzMonoWithTheAudioIntact() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-convert-source-\(UUID().uuidString).wav")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-convert-output-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        // 44.1 kHz stereo — deliberately not the target format. Scoped so the writer is
        // released: AVAudioFile does not finalise its header until it deallocates.
        let inFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        try {
            let file = try AVAudioFile(forWriting: source, settings: inFormat.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            for channel in 0..<2 {
                for frame in 0..<44_100 {
                    buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.05) * 0.4)
                }
            }
            try file.write(from: buffer)
        }()

        let duration = try AudioFileConverter.convert(source, to: destination)
        #expect(abs(duration - 1.0) < 0.01)

        let converted = try AVAudioFile(forReading: destination)
        #expect(converted.fileFormat.sampleRate == 16_000)
        #expect(converted.fileFormat.channelCount == 1)
        let convertedDuration = Double(converted.length) / converted.fileFormat.sampleRate
        #expect(abs(convertedDuration - 1.0) < 0.1, "1s in, \(convertedDuration)s out")

        // The audio survived, rather than a correctly shaped file of silence.
        let read = try #require(AVAudioPCMBuffer(
            pcmFormat: converted.processingFormat,
            frameCapacity: AVAudioFrameCount(converted.length)
        ))
        try converted.read(into: read)
        var sum = 0.0
        if let channel = read.floatChannelData {
            for index in 0..<Int(read.frameLength) { sum += Double(channel[0][index] * channel[0][index]) }
        }
        #expect((sum / Double(read.frameLength)).squareRoot() > 0.05, "converted audio is silent")
    }

    @Test func conversionRejectsAnEmptyFile() throws {
        let source = try Self.silentWAV(seconds: 0)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-convert-empty-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        #expect(throws: AudioFileConverter.ConversionError.self) {
            try AudioFileConverter.convert(source, to: destination)
        }
    }

    // MARK: - Helpers

    private static func silentWAV(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-file-transcription-\(UUID().uuidString).wav")
        let format = AudioFileConverter.targetFormat
        // Scoped so the writer is released before the file is read back.
        try {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let frames = AVAudioFrameCount(seconds * 16_000)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            try file.write(from: buffer)
        }()
        return url
    }
}

private actor CallCounter {
    private(set) var count = 0

    func next() -> Int {
        defer { count += 1 }
        return count
    }
}
