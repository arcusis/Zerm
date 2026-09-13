import Foundation
import os

/// The choices a file is transcribed with, captured when the file is added.
struct FileTranscriptionOptions: Equatable, Sendable {
    var modelName: String
    var modelDisplayName: String
    var languageCode: String
    var identifySpeakers = true
    var speakerCount: SpeakerCount = .automatic
}

/// Transcribes dropped audio and video files one at a time.
///
/// Each job converts its file to a 16 kHz WAV in a private work folder. With speaker
/// identification on it diarizes first and then transcribes speaker by speaker, so every line's
/// speaker comes from diarization; otherwise, or when diarization fails, it transcribes in plain
/// windows. Transcription runs at background inference priority (Dictation always goes first,
/// see `TranscriptionInferenceScheduler`), and the result is saved to History. The steps are
/// injected so the state machine is testable without models.
@MainActor
final class FileTranscriptionQueue: ObservableObject {
    struct Job: Identifiable, Equatable {
        enum State: Equatable {
            case queued
            case converting
            case transcribing(progress: Double)
            case diarizing(progress: Double)
            case completed
            case failed(FileTranscriptionError)
            case cancelled

            var isFinished: Bool {
                switch self {
                case .completed, .failed, .cancelled: true
                default: false
                }
            }
        }

        let id: UUID
        let sourceURL: URL
        let options: FileTranscriptionOptions
        var state: State = .queued
        var isCancelling = false
        var transcript: FileTranscript?

        var fileName: String { sourceURL.lastPathComponent }
    }

    struct Steps {
        var convert: @Sendable (_ source: URL, _ destination: URL) async throws -> TimeInterval
        /// `turns` are the diarized speaker turns, or `nil` to transcribe without speakers.
        var transcribe: @Sendable (
            _ audio: URL,
            _ options: FileTranscriptionOptions,
            _ turns: [SpeakerTurn]?,
            _ onProgress: @escaping @Sendable (Double) async -> Void
        ) async throws -> WindowedFileTranscriber.Transcript
        var diarize: @Sendable (
            _ audio: URL,
            _ speakers: SpeakerCount,
            _ onProgress: @escaping @Sendable (Double) async -> Void
        ) async throws -> [SpeakerTurn]
        var save: @MainActor (_ transcript: FileTranscript, _ audio: URL, _ transcriptionDuration: TimeInterval) throws -> Void
    }

    @Published private(set) var jobs: [Job] = []
    /// Options the user picked for new files; `nil` follows the current Dictation model and
    /// language until they change something.
    @Published var chosenOptions: FileTranscriptionOptions?
    /// Set when files arrive from Finder or the Dock, so the main window shows this page.
    @Published var isRevealRequested = false

    private let steps: Steps
    private let workDirectory: URL
    private let defaultOptions: @MainActor () -> FileTranscriptionOptions
    private var runningTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "FileTranscriptionQueue")

    /// `workDirectory` holds converted audio while jobs run. Leftovers from a previous launch
    /// are deleted here, before any job exists.
    init(
        steps: Steps,
        workDirectory: URL,
        defaultOptions: @escaping @MainActor () -> FileTranscriptionOptions
    ) {
        self.steps = steps
        self.workDirectory = workDirectory
        self.defaultOptions = defaultOptions
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// The options new files are added with.
    var options: FileTranscriptionOptions {
        get { chosenOptions ?? defaultOptions() }
        set { chosenOptions = newValue }
    }

    var hasFinishedJobs: Bool { jobs.contains { $0.state.isFinished } }

    // MARK: - Commands

    func add(_ urls: [URL]) {
        for url in urls {
            var job = Job(id: UUID(), sourceURL: url, options: options)
            if !AudioFileConverter.isSupported(url) {
                job.state = .failed(.unsupportedFile)
            }
            jobs.append(job)
        }
        startNextJob()
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .queued:
            jobs[index].state = .cancelled
        case .converting, .transcribing, .diarizing:
            jobs[index].isCancelling = true
            runningTask?.cancel()
        case .completed, .failed, .cancelled:
            break
        }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .failed, .cancelled:
            jobs[index].state = AudioFileConverter.isSupported(jobs[index].sourceURL) ? .queued : .failed(.unsupportedFile)
            jobs[index].transcript = nil
            startNextJob()
        default:
            break
        }
    }

    /// Removes a job from the list. A completed transcript stays in History.
    func remove(_ id: UUID) {
        cancel(id)
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    // MARK: - Processing

    private func startNextJob() {
        guard runningTask == nil,
              let job = jobs.first(where: { $0.state == .queued }) else { return }
        setState(.converting, for: job.id)
        runningTask = Task(priority: .utility) { [weak self] in
            await self?.run(job)
            self?.runningTask = nil
            self?.startNextJob()
        }
    }

    private func run(_ job: Job) async {
        let started = Date()
        let audio = workDirectory.appendingPathComponent("\(job.id.uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audio) }

        do {
            guard !job.options.modelName.isEmpty else { throw FileTranscriptionError.noModelSelected }
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let duration = try await steps.convert(job.sourceURL, audio)
            try Task.checkCancellation()

            var turns: [SpeakerTurn]?
            var speakerStatus = FileTranscript.SpeakerStatus.notRequested
            if job.options.identifySpeakers {
                setState(.diarizing(progress: 0), for: job.id)
                do {
                    let found = try await steps.diarize(audio, job.options.speakerCount) { [weak self] progress in
                        await self?.setProgress(progress, for: job.id)
                    }
                    // No diarized speech: transcribe the whole file anyway rather than nothing.
                    turns = found.isEmpty ? nil : found
                    speakerStatus = .identified
                } catch {
                    try Task.checkCancellation()
                    // The words are worth more than the labels: deliver the transcript anyway.
                    logger.error("Speaker identification failed: \(error.localizedDescription, privacy: .public)")
                    speakerStatus = .failed
                }
            }
            try Task.checkCancellation()

            setState(.transcribing(progress: 0), for: job.id)
            let transcribed = try await steps.transcribe(audio, job.options, turns) { [weak self] progress in
                await self?.setProgress(progress, for: job.id)
            }
            try Task.checkCancellation()

            let transcript = FileTranscript(
                sourceFileName: job.fileName,
                duration: duration,
                modelName: job.options.modelDisplayName,
                languageCode: job.options.languageCode,
                speakerStatus: speakerStatus,
                segments: transcribed.segments,
                gaps: transcribed.gaps
            )
            guard !transcript.isEmpty else { throw FileTranscriptionError.noSpeech }
            try steps.save(transcript, audio, Date().timeIntervalSince(started))

            update(job.id) {
                $0.transcript = transcript
                $0.state = .completed
            }
        } catch {
            let state: Job.State = Task.isCancelled || error is CancellationError
                ? .cancelled
                : .failed(FileTranscriptionError(error, modelName: job.options.modelDisplayName))
            if case .failed(let reason) = state {
                logger.error("File transcription failed: \(reason.message, privacy: .public)")
            }
            setState(state, for: job.id)
        }
    }

    private func setState(_ state: Job.State, for id: UUID) {
        update(id) {
            $0.state = state
            if state.isFinished { $0.isCancelling = false }
        }
    }

    /// Progress only moves forward and publishes in whole percents, so an hours-long file does
    /// not redraw the list for every window.
    private func setProgress(_ progress: Double, for id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let value = (min(1, max(0, progress)) * 100).rounded(.down) / 100
        switch job.state {
        case .transcribing(let current) where value > current:
            update(id) { $0.state = .transcribing(progress: value) }
        case .diarizing(let current) where value > current:
            update(id) { $0.state = .diarizing(progress: value) }
        default:
            break
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }
}
