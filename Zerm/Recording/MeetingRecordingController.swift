import Combine
import Foundation
import OSLog

/// Drives one meeting end to end: capture, live transcript, and the finished result.
///
/// Kept apart from `MeetingRecordingSession` so capture has no opinion about transcription —
/// the session is useful on its own, and the transcriber can be swapped or switched off without
/// touching the audio path.
@MainActor
final class MeetingRecordingController: ObservableObject {

    @Published private(set) var segments: [MeetingTranscriber.Segment] = []
    @Published private(set) var lastRecording: MeetingRecordingSession.Recording?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTranscribing = false

    /// Who spoke when, in the room. Empty when diarisation is off or the model is still loading.
    @Published private(set) var speakerTurns: [MeetingDiarizer.Turn] = []
    @Published private(set) var isPreparingDiarizer = false

    /// Summary, actions and chapters, produced once the meeting has stopped.
    @Published private(set) var summary: MeetingSummarizer.Result?
    @Published private(set) var isSummarising = false
    @Published private(set) var summaryError: String?

    /// Distinct voices heard so far.
    var speakerCount: Int {
        Set(speakerTurns.map(\.speakerIndex)).count
    }

    #if DEBUG
    /// Injects diarisation turns so attribution can be tested without loading the model.
    func applyTurnsForTesting(_ turns: [MeetingDiarizer.Turn]) {
        speakerTurns = turns
    }
    #endif

    /// The voice that was speaking for most of a transcript line, if any.
    ///
    /// Transcription windows and diarisation turns are cut on different boundaries, so the two
    /// are matched by overlap rather than by index — the speaker who held the floor longest
    /// during the line is the one it is attributed to.
    func speakerLabel(for segment: MeetingTranscriber.Segment) -> String? {
        var overlapBySpeaker: [Int: TimeInterval] = [:]
        for turn in speakerTurns {
            let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
            guard overlap > 0 else { continue }
            overlapBySpeaker[turn.speakerIndex, default: 0] += overlap
        }
        guard let best = overlapBySpeaker.max(by: { $0.value < $1.value })?.key else { return nil }
        return "Speaker \(best + 1)"
    }

    let session = MeetingRecordingSession()

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingRecordingController")
    private var transcriber: MeetingTranscriber?
    private var diarizer: MeetingDiarizer?
    private weak var engine: ZermEngine?
    private var cancellables = Set<AnyCancellable>()

    init(engine: ZermEngine?) {
        self.engine = engine
        // The session is a separate observable object; republish so a view watching the
        // controller sees clock and level changes too.
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var isRecording: Bool { session.state == .recording }

    var transcript: String {
        segments.map(\.text).joined(separator: " ")
    }

    // MARK: - Control

    func start(
        sources: MeetingRecordingSession.Sources = .all,
        transcribeLive: Bool = true,
        identifySpeakers: Bool = true
    ) {
        errorMessage = nil
        segments = []
        speakerTurns = []
        lastRecording = nil
        summary = nil
        summaryError = nil

        if identifySpeakers && sources.contains(.microphone) {
            let diarizer = MeetingDiarizer()
            diarizer.onTurns = { [weak self] turns in
                self?.speakerTurns = turns
            }
            self.diarizer = diarizer
            session.onMicrophoneChunk = { [weak diarizer] data in
                diarizer?.append(data)
            }
            // Loading the model can take a while on first use and may need a download, so the
            // recording starts immediately and speaker labels simply begin once it is ready.
            isPreparingDiarizer = true
            Task { [weak self] in
                await diarizer.prepare()
                self?.isPreparingDiarizer = false
            }
        } else {
            session.onMicrophoneChunk = nil
        }

        if transcribeLive {
            guard engine?.transcriptionModelManager.currentTranscriptionModel != nil else {
                errorMessage = "Choose a dictation model before recording a meeting with a live transcript."
                return
            }
            let engine = self.engine
            let transcriber = MeetingTranscriber { url in
                try await Self.transcribe(url: url, engine: engine)
            }
            transcriber.onSegment = { [weak self] segment in
                guard let self else { return }
                self.segments.append(segment)
                // Journalled the moment it exists, so a crash costs at most the window in flight
                // rather than the whole meeting.
                if let folder = self.session.folder {
                    MeetingRecordingStore.appendToJournal(
                        in: folder,
                        line: .init(
                            start: segment.start,
                            end: segment.end,
                            text: segment.text,
                            speaker: self.speakerLabel(for: segment)
                        )
                    )
                }
            }
            transcriber.start()
            self.transcriber = transcriber
            isTranscribing = true

            session.onTranscriptionChunk = { [weak transcriber] data in
                transcriber?.append(data)
            }
        } else {
            session.onTranscriptionChunk = nil
        }

        do {
            try session.start(sources: sources)
        } catch {
            transcriber?.cancel()
            self.transcriber = nil
            isTranscribing = false
            diarizer = nil
            isPreparingDiarizer = false
            session.onTranscriptionChunk = nil
            session.onMicrophoneChunk = nil
            errorMessage = error.localizedDescription
            logger.error("Meeting recording failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        let recording = session.stop()
        session.onTranscriptionChunk = nil
        session.onMicrophoneChunk = nil
        lastRecording = recording

        diarizer?.finish()
        diarizer = nil
        isPreparingDiarizer = false

        if let transcriber {
            // The tail of the meeting is still being transcribed; wait for it rather than
            // handing back a transcript that stops short of the last thing anyone said.
            await transcriber.finish()
            self.transcriber = nil
        }
        isTranscribing = false

        if let recording {
            logger.notice("Meeting saved to \(recording.folder.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: - Summary

    /// Runs after the transcript is complete, never during recording: summarising a partial
    /// meeting wastes a model pass and produces conclusions the meeting had not reached yet.
    func summarise() async {
        guard !segments.isEmpty else { return }
        isSummarising = true
        summaryError = nil
        defer { isSummarising = false }

        let engine = self.engine
        let lines = segments.map { segment in
            MeetingRecordingStore.Sidecar.Line(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speaker: speakerLabel(for: segment)
            )
        }

        let summariser = MeetingSummarizer { system, text in
            try await Self.complete(systemPrompt: system, text: text, engine: engine)
        }

        do {
            summary = try await summariser.summarize(lines: lines)
        } catch {
            summaryError = error.localizedDescription
            logger.error("Meeting summary failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private static func complete(systemPrompt: String, text: String, engine: ZermEngine?) async throws -> String {
        guard let service = engine?.enhancementService else {
            throw MeetingRecordingSession.SessionError.noSourcesSelected
        }
        return try await service.summariseMeeting(systemPrompt: systemPrompt, text: text)
    }

    // MARK: - Transcription

    /// Uses whichever model the user already selected for dictation, so a meeting transcript
    /// follows the same local-or-cloud choice everything else in Zerm does.
    @MainActor
    private static func transcribe(url: URL, engine: ZermEngine?) async throws -> String {
        guard let engine else {
            throw MeetingRecordingSession.SessionError.noSourcesSelected
        }
        guard let model = engine.transcriptionModelManager.currentTranscriptionModel else {
            throw ZermEngineError.modelLoadFailed
        }
        return try await engine.serviceRegistry.transcribe(audioURL: url, model: model)
    }
}
