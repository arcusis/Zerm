import AVFoundation
import Foundation
import Testing
import FluidAudio
@testable import Zerm

/// Exercises the meeting recorder's logic without audio hardware.
///
/// Capture itself needs a real device and the system-audio permission, but the parts most
/// likely to be quietly wrong — how audio is cut into transcription windows, how a spoken line
/// is attributed to a speaker, and whether a recording interrupted by a crash still survives —
/// are all pure enough to pin down here.
struct MeetingRecordingTests {

    /// 16 kHz mono Int16, the one format the whole recording path uses.
    private static func pcm(seconds: Double, value: Int16 = 1_000) -> Data {
        let samples = Int(seconds * 16_000)
        var data = Data(capacity: samples * 2)
        for _ in 0..<samples {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private final class Windows: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [AVAudioFramePosition] = []

        func record(_ url: URL) {
            let count = (try? AVAudioFile(forReading: url))?.length ?? 0
            lock.lock(); frames.append(count); lock.unlock()
        }

        var all: [AVAudioFramePosition] {
            lock.lock(); defer { lock.unlock() }
            return frames
        }
    }

    // MARK: - Windowing

    @Test func transcriberCutsAWindowOncePastTheThreshold() async {
        let windows = Windows()
        let transcriber = MeetingTranscriber(windowSeconds: 1, overlapSeconds: 0.25) { url in
            windows.record(url)
            return "text"
        }
        transcriber.start()

        // Two seconds of audio, delivered the way Core Audio does it: in small chunks.
        for _ in 0..<20 {
            transcriber.append(Self.pcm(seconds: 0.1))
        }
        await transcriber.finish()

        let all = windows.all
        #expect(!all.isEmpty, "no transcription window was ever produced")
        // Every full window must be exactly the configured length; a short one means the
        // overlap arithmetic is eating audio.
        for frames in all.dropLast() {
            #expect(frames == 16_000, "expected a 1s window, got \(frames) frames")
        }
    }

    /// A single large chunk must not leave more than one window's worth sitting in the buffer.
    ///
    /// This is the case that breaks silently: audio arriving faster than windows are cut means
    /// the pending buffer grows without bound, and the transcript falls further behind the
    /// meeting the longer it runs.
    @Test func transcriberDrainsABacklogRatherThanBuffering() async {
        let windows = Windows()
        let transcriber = MeetingTranscriber(windowSeconds: 1, overlapSeconds: 0.25) { url in
            windows.record(url)
            return "text"
        }
        transcriber.start()

        // Five seconds in one delivery.
        transcriber.append(Self.pcm(seconds: 5))
        await transcriber.finish()

        // Four full windows plus whatever the flush leaves.
        #expect(windows.all.count >= 4, "one large chunk produced only \(windows.all.count) window(s); the backlog was not drained")
    }

    @Test func transcriberEmitsNothingForSilenceItCannotTranscribe() async {
        let transcriber = MeetingTranscriber(windowSeconds: 1, overlapSeconds: 0) { _ in "   " }
        let box = Windows()
        _ = box
        var segments: [MeetingTranscriber.Segment] = []
        transcriber.onSegment = { segments.append($0) }
        transcriber.start()
        transcriber.append(Self.pcm(seconds: 2))
        await transcriber.finish()

        #expect(segments.isEmpty, "whitespace-only transcriptions must not become transcript lines")
    }

    // MARK: - Speaker attribution

    @MainActor
    @Test func speakerIsTheVoiceHoldingTheFloorLongest() async {
        let controller = MeetingRecordingController(engine: nil)
        let segment = MeetingTranscriber.Segment(start: 10, end: 20, text: "hello")

        // Speaker 0 covers 2s of the line, speaker 1 covers 7s.
        controller.applyTurnsForTesting([
            .init(speakerIndex: 0, start: 9, end: 12, isFinal: true),
            .init(speakerIndex: 1, start: 12, end: 19, isFinal: true)
        ])

        #expect(controller.speakerLabel(for: segment) == "Speaker 2")
        #expect(controller.speakerCount == 2)
    }

    @MainActor
    @Test func nonOverlappingTurnsAttributeToNobody() async {
        let controller = MeetingRecordingController(engine: nil)
        let segment = MeetingTranscriber.Segment(start: 100, end: 110, text: "hello")
        controller.applyTurnsForTesting([
            .init(speakerIndex: 0, start: 0, end: 5, isFinal: true)
        ])

        #expect(controller.speakerLabel(for: segment) == nil)
    }

    // MARK: - Store

    @MainActor
    @Test func sidecarSurvivesARoundTrip() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = MeetingRecordingStore()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let segments = [
            MeetingTranscriber.Segment(start: 0, end: 5, text: "first"),
            MeetingTranscriber.Segment(start: 5, end: 9, text: "second")
        ]

        store.writeSidecar(
            into: folder,
            startedAt: started,
            duration: 9,
            segments: segments,
            speakerLabel: { $0.start == 0 ? "Speaker 1" : nil },
            speakerCount: 1
        )

        let read = try #require(store.readSidecar(in: folder))
        #expect(read.duration == 9)
        #expect(read.speakerCount == 1)
        #expect(read.transcript == "first second")
        #expect(read.segments.count == 2)
        #expect(read.segments[0].speaker == "Speaker 1")
        #expect(read.segments[1].speaker == nil)
        #expect(Int(read.startedAt.timeIntervalSince1970) == 1_700_000_000)
    }
}

extension MeetingRecordingTests {

    /// A recording killed mid-meeting must still surface its transcript.
    @MainActor
    @Test func journalRecoversATranscriptFromAnInterruptedRecording() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for (index, text) in ["one", "two", "three"].enumerated() {
            MeetingRecordingStore.appendToJournal(
                in: folder,
                line: .init(
                    start: Double(index) * 30,
                    end: Double(index + 1) * 30,
                    text: text,
                    speaker: "Speaker \(index % 2 + 1)"
                )
            )
        }

        let store = MeetingRecordingStore()
        let lines = store.readJournal(in: folder)

        #expect(lines.count == 3, "every journalled line must survive; got \(lines.count)")
        #expect(lines.map(\.text) == ["one", "two", "three"], "journal order must be preserved")
        #expect(lines[1].speaker == "Speaker 2")
        // No sidecar was ever written — this is exactly the crash case.
        #expect(store.readSidecar(in: folder) == nil)
    }
}

// MARK: - Summarisation

struct MeetingSummarizerTests {

    private func line(_ start: Double, _ text: String, speaker: String? = nil)
        -> MeetingRecordingStore.Sidecar.Line {
        .init(start: start, end: start + 5, text: text, speaker: speaker)
    }

    @Test func parsesTheThreeSections() {
        let raw = """
            SUMMARY
            The team agreed the launch slips a week.

            ACTIONS
            - Sarah to redo the pricing page
            - Tom to email the beta list

            CHAPTERS
            - 00:00 Launch date
            - 12:30 Pricing
            """
        let result = MeetingSummarizer.parse(raw, lines: [line(0, "a"), line(900, "b")])

        #expect(result.summary == "The team agreed the launch slips a week.")
        #expect(result.actionItems.count == 2)
        #expect(result.actionItems[0] == "Sarah to redo the pricing page")
        #expect(result.chapters.count == 2)
        #expect(result.chapters[1].start == 750)
        #expect(result.chapters[1].title == "Pricing")
    }

    /// A model that ignores the format must still produce something useful.
    @Test func unformattedRepliesStillYieldASummary() {
        let result = MeetingSummarizer.parse("They talked about the launch.", lines: [line(0, "a")])
        #expect(result.summary == "They talked about the launch.")
        #expect(result.actionItems.isEmpty)
    }

    /// Timestamps past the end of the meeting are hallucinated.
    @Test func chaptersBeyondTheRecordingAreDropped() {
        // The meeting runs to 10:05, so 00:10 is real and 59:00 cannot be.
        let raw = "SUMMARY\nx\n\nCHAPTERS\n- 00:10 Real\n- 59:00 Invented"
        let result = MeetingSummarizer.parse(raw, lines: [line(0, "a"), line(600, "b")])

        // Never subscript in an expectation: an out-of-range index traps and takes the whole
        // test process down with it, hiding every other result.
        #expect(result.chapters.count == 1)
        #expect(result.chapters.first?.title == "Real")
    }

    /// A chapter exactly at the end of the meeting is still real.
    @Test func chaptersAtTheBoundaryAreKept() {
        let raw = "SUMMARY\nx\n\nCHAPTERS\n- 00:05 Edge"
        let result = MeetingSummarizer.parse(raw, lines: [line(0, "a")])
        #expect(result.chapters.first?.title == "Edge")
    }

    @Test func longTranscriptsAreFoldedThroughChunkSummaries() async throws {
        let lines = (0..<400).map { line(Double($0) * 5, "This is a sentence of meeting talk number \($0).") }
        let calls = Calls()

        let summarizer = MeetingSummarizer(
            complete: { system, _ in
                await calls.record(system)
                return "SUMMARY\nfolded\n\nACTIONS\n- do the thing"
            },
            chunkCharacters: 2_000
        )
        let result = try await summarizer.summarize(lines: lines)

        let recorded = await calls.all
        #expect(recorded.count > 2, "a long transcript should be chunked, saw \(recorded.count) call(s)")
        // Last call is the fold-up; everything before it is a chunk pass.
        #expect(recorded.last?.contains("summarising a meeting") == true)
        #expect(result.actionItems == ["do the thing"])
    }

    @Test func shortTranscriptsSkipChunking() async throws {
        let calls = Calls()
        let summarizer = MeetingSummarizer(
            complete: { system, _ in
                await calls.record(system)
                return "SUMMARY\nshort"
            },
            chunkCharacters: 10_000
        )
        _ = try await summarizer.summarize(lines: [line(0, "hello there")])
        let recorded = await calls.all
        #expect(recorded.count == 1, "a short transcript needs exactly one pass")
    }

    @Test func emptyTranscriptNeverCallsTheModel() async throws {
        let calls = Calls()
        let summarizer = MeetingSummarizer(complete: { system, _ in
            await calls.record(system)
            return "x"
        })
        let result = try await summarizer.summarize(lines: [])
        #expect(await calls.all.isEmpty)
        #expect(result.isEmpty)
    }

    private actor Calls {
        private var systems: [String] = []
        func record(_ system: String) { systems.append(system) }
        var all: [String] { systems }
    }
}

extension MeetingSummarizerTests {

    /// A summary must survive being written and reopened, or the library shows a blank card
    /// for a meeting that was summarised perfectly well.
    @MainActor
    @Test func summarySurvivesTheSidecarRoundTrip() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = MeetingRecordingStore()
        let summary = MeetingSummarizer.Result(
            summary: "Launch slips a week.",
            actionItems: ["Sarah redoes pricing"],
            chapters: [.init(start: 30, title: "Launch date")]
        )

        store.writeSidecar(
            into: folder,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 60,
            segments: [.init(start: 0, end: 60, text: "hello")],
            speakerLabel: { _ in "Speaker 1" },
            speakerCount: 1,
            summary: summary
        )

        let read = try #require(store.readSidecar(in: folder))
        #expect(read.summary == summary)
        #expect(read.summary?.chapters.first?.title == "Launch date")
    }
}

/// End-to-end exercise of the whole capture session.
///
/// Runs inside the app bundle, so it has the real microphone grant and real audio devices —
/// this is the only place `MeetingRecordingSession` can be driven for real.
@MainActor
struct MeetingSessionIntegrationTests {

    @Test func sessionRecordsBothTracksAndSavesThem() async throws {
        // Injected, not global: tests run in parallel and must not share a library location.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-lib-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = MeetingRecordingSession(libraryRoot: root)

        var chunkBytes = 0
        var micBytes = 0
        session.onTranscriptionChunk = { chunkBytes += $0.count }
        session.onMicrophoneChunk = { micBytes += $0.count }

        do {
            try session.start(sources: .all)
        } catch {
            // A CI box with no input device is a legitimate skip, not a failure.
            print("session could not start: \(error.localizedDescription)")
            return
        }

        #expect(session.state == .recording)
        try await Task.sleep(for: .seconds(3))

        let recording = session.stop()
        let saved = try #require(recording, "stop() must hand back the finished recording")

        #expect(session.state == .idle)
        #expect(saved.duration >= 2.5, "expected ~3s, got \(saved.duration)")
        #expect(FileManager.default.fileExists(atPath: saved.folder.path))

        // Whichever tracks engaged must be real, readable audio files of about the right length.
        for track in [saved.microphoneTrack, saved.systemAudioTrack].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: track.path) {
            let file = try AVAudioFile(forReading: track)
            let duration = Double(file.length) / file.fileFormat.sampleRate
            #expect(file.fileFormat.sampleRate == 16_000,
                    "\(track.lastPathComponent) should be 16 kHz, was \(file.fileFormat.sampleRate)")
            #expect(file.fileFormat.channelCount == 1)
            #expect(duration >= 1.5,
                    "\(track.lastPathComponent) holds only \(duration)s")
            print("track \(track.lastPathComponent): \(duration)s at \(file.fileFormat.sampleRate) Hz")
        }

        print("chunks=\(chunkBytes) micChunks=\(micBytes) duration=\(saved.duration)")
        #expect(chunkBytes > 0, "no audio ever reached the transcription feed")

        try? FileManager.default.removeItem(at: saved.folder)
    }

    @Test func startingTwiceIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-lib-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = MeetingRecordingSession(libraryRoot: root)
        guard (try? session.start(sources: .microphone)) != nil else { return }
        defer { _ = session.stop() }

        #expect(throws: MeetingRecordingSession.SessionError.self) {
            try session.start(sources: .microphone)
        }
    }

    @Test func noSourcesIsRejectedBeforeAnythingIsCreated() {
        let session = MeetingRecordingSession()
        #expect(throws: MeetingRecordingSession.SessionError.self) {
            try session.start(sources: [])
        }
    }
}

/// The diarizer has to actually load its model and produce turns, or speaker identification is
/// a label in the UI with nothing behind it.
@MainActor
struct MeetingDiarizerIntegrationTests {

    @Test func diarizerLoadsAndProducesTurnsForSpeech() async throws {
        let diarizer = MeetingDiarizer()
        await diarizer.prepare()

        // Checked here, immediately, with nothing in between: if prepare() returned without
        // recording an outcome the fault is in prepare() itself, not in anything downstream.
        var turns: [MeetingDiarizer.Turn] = []
        diarizer.onTurns = { turns = $0 }

        // Real synthesised speech, not a tone. A diarisation model finds no speakers in a
        // sine wave — correctly — so a tone fixture proves nothing about whether it works.
        let speech = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-diar-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: speech) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", speech.path, "--data-format=LEI16@16000", "-r", "170",
            "Good morning everyone, thanks for joining the call today. "
            + "I wanted to walk through the launch plan and the open questions. "
            + "The pricing page still needs another pass before we ship anything."
        ]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0,
              let file = try? AVAudioFile(forReading: speech) else {
            Issue.record("could not synthesise speech for the diarizer fixture")
            return
        }

        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)

        // Convert to the 16 kHz mono Int16 chunks the diarizer consumes.
        var pcm = Data()
        if let ch = buffer.floatChannelData {
            for frame in 0..<Int(buffer.frameLength) {
                let value = Int16(max(-1, min(1, ch[0][frame])) * 32_767)
                withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        #expect(pcm.count > 16_000, "fixture produced only \(pcm.count) bytes of speech")

        // Feed it in realistic chunks.
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 8_000, pcm.count)
            diarizer.append(pcm.subdata(in: offset..<end))
            offset = end
        }

        let wasAvailable = diarizer.isAvailable

        // Inference runs on its own queue; give it time to work through the backlog.
        try await Task.sleep(for: .seconds(12))
        diarizer.finish()
        try await Task.sleep(for: .seconds(2))

        // Assert on state rather than printing: stdout from the test host is not captured, so
        // a print here proves nothing to anyone reading the results.
        // Read before finish(): tearing the session down legitimately clears `isAvailable`.
        #expect(diarizer.didAttemptLoad, "prepare() never resolved either way")

        if wasAvailable {
            #expect(!turns.isEmpty,
                    "the model loaded but produced no turns at all from 20s of audio")
            #expect(turns.allSatisfy { $0.end >= $0.start }, "a turn ended before it began")
            #expect(turns.allSatisfy { $0.speakerIndex >= 0 })
        } else {
            // A machine that cannot fetch the model is a legitimate skip — but the recording
            // path must still have survived it, which is what the assertions above cover.
            Issue.record("diarizer model unavailable on this machine; turn production unverified")
        }
    }
}

struct DiarizerModelLoadDiagnostic {
    /// Surfaces why the diarization model will not load, which `MeetingDiarizer` deliberately
    /// swallows so a failure cannot take a recording down with it.
    @Test func reportsWhyTheModelDoesNotLoad() async throws {
        do {
            let d = LSEENDDiarizer()
            try await d.initialize(variant: .dihard3)
            #expect(d.isAvailable, "initialize() returned but the diarizer is not available")
        } catch {
            Issue.record("LSEENDDiarizer.initialize failed: \(error) — \(error.localizedDescription)")
        }
    }
}

@MainActor
struct MeetingImportTests {

    /// An imported file must come out in exactly the format a recorded one does, or everything
    /// downstream has to learn about two kinds of recording.
    @Test func importConvertsToTheRecorderFormat() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-import-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: source) }

        // 44.1 kHz stereo — deliberately not the recorder's format.
        // Scoped so the writer is released: an AVAudioFile does not finalise its header until
        // it deallocates, and reading it while the writer is alive reports zero frames.
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
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

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingRecordingStore(libraryRoot: root)
        let item = try store.importRecording(from: source)
        try verifyImported(item)
    }

    private func verifyImported(_ item: MeetingRecordingStore.Item) throws {
        let track = try #require(item.microphoneTrack)
        let imported = try AVAudioFile(forReading: track)
        #expect(imported.fileFormat.sampleRate == 16_000)
        #expect(imported.fileFormat.channelCount == 1)

        let duration = Double(imported.length) / imported.fileFormat.sampleRate
        #expect(abs(duration - 1.0) < 0.1, "1s in, \(duration)s out")

        // And the audio survived, rather than a correctly-shaped file of silence.
        let read = AVAudioPCMBuffer(pcmFormat: imported.processingFormat,
                                    frameCapacity: AVAudioFrameCount(imported.length))!
        try imported.read(into: read)
        var sum = 0.0
        if let ch = read.floatChannelData {
            for i in 0..<Int(read.frameLength) { sum += Double(ch[0][i] * ch[0][i]) }
        }
        #expect((sum / Double(read.frameLength)).squareRoot() > 0.05, "imported audio is silent")
    }

    @Test func meetingAppsAreRecognisedAndMarketingPagesAreNot() {
        #expect(MeetingAppDetector.isMeetingApp(bundleID: "us.zoom.xos"))
        #expect(!MeetingAppDetector.isMeetingApp(bundleID: "com.apple.Safari"))
        #expect(MeetingAppDetector.isMeetingURL("https://meet.google.com/abc-defg-hij"))
        #expect(MeetingAppDetector.isMeetingURL("https://acme.zoom.us/j/9876543210"))
        // The bare marketing site is not a meeting.
        #expect(!MeetingAppDetector.isMeetingURL("https://zoom.us/pricing"))
    }
}

struct MeetingPlaybackTests {

    private func sidecar(_ lines: [(Double, Double, String)]) -> MeetingRecordingStore.Sidecar {
        .init(
            startedAt: Date(timeIntervalSince1970: 0),
            duration: lines.last?.1 ?? 0,
            transcript: lines.map(\.2).joined(separator: " "),
            speakerCount: 1,
            segments: lines.map { .init(start: $0.0, end: $0.1, text: $0.2, speaker: nil) },
            summary: nil
        )
    }

    /// Playback highlights whichever line is being spoken.
    @Test func theLineUnderThePlayheadIsFound() {
        let s = sidecar([(0, 5, "one"), (5, 10, "two"), (10, 15, "three")])
        #expect(s.line(at: 0) == 0)
        #expect(s.line(at: 4.9) == 0)
        #expect(s.line(at: 5) == 1, "a boundary belongs to the line starting there")
        #expect(s.line(at: 12) == 2)
    }

    /// Past the end the cursor stays on the final line rather than vanishing.
    @Test func thePlayheadPastTheEndKeepsTheLastLine() {
        let s = sidecar([(0, 5, "one"), (5, 10, "two")])
        #expect(s.line(at: 30) == 1)
    }

    /// A gap between lines — silence — highlights nothing.
    @Test func silenceBetweenLinesHighlightsNothing() {
        let s = sidecar([(0, 5, "one"), (20, 25, "two")])
        #expect(s.line(at: 12) == nil)
    }

    @Test func anEmptyTranscriptHasNoActiveLine() {
        #expect(sidecar([]).line(at: 0) == nil)
    }
}
