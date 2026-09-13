import AVFoundation
import Foundation
import Testing
@testable import Zerm

/// Planning speaker spans from diarized turns, and transcribing a file span by span. The planner
/// is pure; the transcriber runs on silent WAV files with a scripted transcription closure.
struct SpeakerTurnTranscriptionTests {

    // MARK: - Planning

    @Test func consecutiveTurnsOfOneSpeakerMerge() {
        let spans = SpeakerTurnPlanner.plan([
            Self.turn(0, 0, 4),
            Self.turn(0, 4.5, 9),
            Self.turn(1, 9, 14)
        ], duration: 20)

        #expect(Self.describe(spans) == [
            "0.00-9.00 audio 0.00-9.00 speaker 0",
            "9.00-14.00 audio 9.00-14.20 speaker 1"
        ])
    }

    @Test func shortTurnIsAbsorbedByTheNearestLongerTurn() {
        let spans = SpeakerTurnPlanner.plan([
            Self.turn(0, 0, 5),
            Self.turn(1, 5.3, 5.8),
            Self.turn(0, 6, 10),
            Self.turn(2, 13, 18)
        ], duration: 18)

        #expect(Self.describe(spans) == [
            "0.00-10.00 audio 0.00-10.20 speaker 0",
            "13.00-18.00 audio 12.80-18.00 speaker 2"
        ])
    }

    @Test func isolatedShortTurnKeepsItsSpeaker() {
        let spans = SpeakerTurnPlanner.plan([
            Self.turn(0, 0, 5),
            Self.turn(1, 9, 9.5),
            Self.turn(0, 14, 20)
        ], duration: 20)

        #expect(Self.describe(spans) == [
            "0.00-5.00 audio 0.00-5.20 speaker 0",
            "9.00-9.50 audio 8.80-9.70 speaker 1",
            "14.00-20.00 audio 13.80-20.00 speaker 0"
        ])
    }

    @Test func longSpeechOfOneSpeakerSplitsAtItsPauses() {
        let spans = SpeakerTurnPlanner.plan([
            Self.turn(0, 0, 20),
            Self.turn(0, 21, 29),
            Self.turn(0, 29.5, 40),
            Self.turn(0, 41, 45)
        ], duration: 50)

        #expect(Self.describe(spans) == [
            "0.00-29.00 audio 0.00-29.20 speaker 0",
            "29.50-45.00 audio 29.30-45.20 speaker 0"
        ])
    }

    @Test func aSingleTurnLongerThanAWindowStaysOneSpan() {
        let spans = SpeakerTurnPlanner.plan([Self.turn(3, 1, 95)], duration: 100)

        #expect(Self.describe(spans) == ["1.00-95.00 audio 0.80-95.20 speaker 3"])
    }

    @Test func runsOfShortTurnsFromDifferentSpeakersShareOneRequest() {
        let spans = SpeakerTurnPlanner.plan([
            Self.turn(0, 0, 10),
            Self.turn(1, 10.2, 11.7),
            Self.turn(2, 11.9, 13.4),
            Self.turn(1, 13.5, 15),
            Self.turn(0, 15.2, 25)
        ], duration: 25)

        #expect(Self.describe(spans) == [
            "0.00-10.00 audio 0.00-10.10 speaker 0",
            "10.20-15.00 audio 10.10-15.10 mixed",
            "15.20-25.00 audio 15.10-25.00 speaker 0"
        ])
        #expect(spans[1].turns.map(\.speakerIndex) == [1, 2, 1])
    }

    @Test func paddingNeverReachesIntoANeighbouringSpan() {
        let spans = SpeakerTurnPlanner.plan([
            Self.turn(0, 0.1, 5),
            Self.turn(1, 5, 10),
            Self.turn(0, 10.3, 15)
        ], duration: 15.1)

        #expect(Self.describe(spans) == [
            "0.10-5.00 audio 0.00-5.00 speaker 0",
            "5.00-10.00 audio 5.00-10.15 speaker 1",
            "10.30-15.00 audio 10.15-15.10 speaker 0"
        ])
        #expect(zip(spans, spans.dropFirst()).allSatisfy { $0.audioEnd <= $1.audioStart })
    }

    @Test func turnsAreSortedClippedAndMadeExclusive() {
        let spans = SpeakerTurnPlanner.plan([
            Self.turn(1, 3, 6),
            Self.turn(0, 0, 4),
            Self.turn(2, 7, 7),
            Self.turn(0, 6, 12)
        ], duration: 10)

        #expect(Self.describe(spans) == [
            "0.00-4.00 audio 0.00-4.00 speaker 0",
            "4.00-6.00 audio 4.00-6.00 speaker 1",
            "6.00-10.00 audio 6.00-10.00 speaker 0"
        ])
    }

    @Test func noTurnsPlanNothing() {
        #expect(SpeakerTurnPlanner.plan([], duration: 30).isEmpty)
    }

    // MARK: - Transcribing by turn

    @Test func eachSpeakerSpanIsTranscribedSeparatelyAndLabelledFromItsTurn() async throws {
        let url = try Self.silentWAV(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = ScriptedTranscription(["good morning everyone", "thanks for joining", "let us begin"])
        let transcriber = SpeakerTurnTranscriber(windowed: WindowedFileTranscriber { window in
            try await calls.next(window)
        })

        let transcript = try await transcriber.transcribeFile(url, turns: [
            Self.turn(0, 0, 6),
            Self.turn(1, 6, 12),
            Self.turn(0, 12, 20)
        ])

        #expect(await calls.durations == [6, 6, 8])
        #expect(transcript.segments.map(\.text) == ["good morning everyone", "thanks for joining", "let us begin"])
        #expect(transcript.segments.map(\.speakerIndex) == [0, 1, 0])
        #expect(transcript.segments.allSatisfy { $0.speakerConfidence == .diarizedTurn })
        #expect(transcript.segments.map(\.start) == [0, 6, 12])
        #expect(transcript.segments.map(\.end) == [6, 12, 20])
    }

    @Test func aLongTurnIsWindowedWithItsSeamsReconciled() async throws {
        let url = try Self.silentWAV(seconds: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = ScriptedTranscription(["alpha beta gamma delta", "gamma delta epsilon"])
        let transcriber = SpeakerTurnTranscriber(windowed: WindowedFileTranscriber { window in
            try await calls.next(window)
        })

        let transcript = try await transcriber.transcribeFile(url, turns: [Self.turn(0, 0, 50)])

        #expect(await calls.durations.count == 2)
        #expect(transcript.segments.map(\.text) == ["alpha beta gamma delta", "epsilon"])
        #expect(transcript.segments.allSatisfy { $0.speakerIndex == 0 })
        #expect(transcript.segments.last?.end == 50)
    }

    @Test func batchedShortTurnsFallBackToEstimatedAttribution() async throws {
        let url = try Self.silentWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = ScriptedTranscription(["yes of course no problem"])
        let transcriber = SpeakerTurnTranscriber(windowed: WindowedFileTranscriber { window in
            try await calls.next(window)
        })

        let transcript = try await transcriber.transcribeFile(url, turns: [
            Self.turn(4, 0, 1.5),
            Self.turn(7, 1.5, 3)
        ])

        #expect(await calls.durations.count == 1)
        #expect(transcript.segments.map(\.speakerIndex) == [4, 7])
        #expect(transcript.segments.allSatisfy { $0.speakerConfidence == .estimatedFromWindow })
        #expect(transcript.segments.map(\.text).joined(separator: " ") == "yes of course no problem")
    }

    @Test func aFailingSpanBecomesAGapWithoutLosingTheRest() async throws {
        let url = try Self.silentWAV(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = ScriptedTranscription(["first speaker", nil, "back again"])
        let transcriber = SpeakerTurnTranscriber(windowed: WindowedFileTranscriber { window in
            try await calls.next(window)
        })

        let transcript = try await transcriber.transcribeFile(url, turns: [
            Self.turn(0, 0, 6),
            Self.turn(1, 6, 12),
            Self.turn(0, 12, 20)
        ])

        #expect(transcript.segments.map(\.text) == ["first speaker", "back again"])
        #expect(transcript.gaps.map(\.start) == [6])
    }

    @Test func repeatedFailuresStopTheJobEarly() async throws {
        let url = try Self.silentWAV(seconds: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = ScriptedTranscription(Array(repeating: nil, count: 10))
        let transcriber = SpeakerTurnTranscriber(windowed: WindowedFileTranscriber { window in
            try await calls.next(window)
        })
        // Ten turns separated by long pauses, so none merge.
        let turns = (0..<10).map { Self.turn($0 % 2, Double($0) * 6, Double($0) * 6 + 3) }

        await #expect(throws: URLError.self) {
            try await transcriber.transcribeFile(url, turns: turns)
        }
        #expect(await calls.durations.count == SpeakerTurnTranscriber.maximumConsecutiveFailures)
    }

    @Test func cancellationStopsBetweenSpans() async throws {
        let url = try Self.silentWAV(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = ScriptedTranscription(["one", "two", "three"])
        let transcriber = SpeakerTurnTranscriber(windowed: WindowedFileTranscriber { window in
            let text = try await calls.next(window)
            withUnsafeCurrentTask { $0?.cancel() }
            return text
        })

        // The job's own task is cancelled from inside its first request.
        let job = Task {
            try await transcriber.transcribeFile(url, turns: [
                Self.turn(0, 0, 6),
                Self.turn(1, 6, 12),
                Self.turn(0, 12, 20)
            ])
        }

        await #expect(throws: CancellationError.self) {
            try await job.value
        }
        #expect(await calls.durations.count == 1)
    }

    // MARK: - Helpers

    private static func turn(_ speaker: Int, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(speakerIndex: speaker, start: start, end: end)
    }

    private static func describe(_ spans: [SpeakerTurnPlanner.Span]) -> [String] {
        spans.map { span in
            let speaker = span.speakerIndex.map { "speaker \($0)" } ?? "mixed"
            return String(
                format: "%.2f-%.2f audio %.2f-%.2f %@",
                span.start, span.end, span.audioStart, span.audioEnd, speaker
            )
        }
    }

    private static func silentWAV(seconds: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-speaker-turns-\(UUID().uuidString).wav")
        let format = AudioFileConverter.targetFormat
        try {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let frames = AVAudioFrameCount(seconds * 16_000)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            try file.write(from: buffer)
        }()
        return url
    }
}

/// Answers each transcription request with the next scripted text; `nil` fails the request.
/// Records the length of every window it was sent.
private actor ScriptedTranscription {
    private var script: [String?]
    private(set) var durations: [TimeInterval] = []

    init(_ script: [String?]) {
        self.script = script
    }

    func next(_ window: URL) throws -> String {
        let file = try AVAudioFile(forReading: window)
        durations.append((Double(file.length) / file.fileFormat.sampleRate * 100).rounded() / 100)
        guard !script.isEmpty, let text = script.removeFirst() else {
            throw URLError(.notConnectedToInternet)
        }
        return text
    }
}
