import Foundation
import SwiftData
import Testing
@testable import Zerm

/// The file transcription queue, History persistence and error mapping. Every step is a closure,
/// so no models, network or the app's own storage are involved.
@MainActor
struct FileTranscriptionQueueTests {

    // MARK: - State machine

    @Test func jobMovesThroughEveryStateToCompleted() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.convert = { _, destination in
            await probe.recordState()
            FileManager.default.createFile(atPath: destination.path, contents: Data())
            return 12
        }
        steps.transcribe = { _, _, turns, onProgress in
            #expect(turns == Self.twoSpeakerTurns)
            await probe.recordState()
            await onProgress(0.5)
            await probe.recordState()
            return Self.labelledTranscript
        }
        steps.diarize = { _, speakers, onProgress in
            #expect(speakers == .fixed(2))
            await probe.recordState()
            await onProgress(0.25)
            await probe.recordState()
            return Self.twoSpeakerTurns
        }
        let queue = Self.queue(steps, probe: probe, speakerCount: .fixed(2))

        queue.add([Self.source("interview.m4a")])
        try await Self.waitUntilIdle(queue)

        // Speakers first, so the transcription can follow them.
        #expect(probe.states == [
            .converting,
            .diarizing(progress: 0),
            .diarizing(progress: 0.25),
            .transcribing(progress: 0),
            .transcribing(progress: 0.5)
        ])
        let job = try #require(queue.jobs.first)
        #expect(job.state == .completed)
        #expect(probe.saved.count == 1)
        #expect(job.transcript == probe.saved.first)
        #expect(job.transcript?.speakerStatus == .identified)
        #expect(job.transcript?.duration == 12)
        #expect(job.transcript?.sourceFileName == "interview.m4a")
        #expect(job.transcript?.segments.map(\.speakerIndex) == [0, 1])
    }

    @Test func filesRunOneAtATime() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.convert = { _, _ in
            await probe.enter()
            try await Task.sleep(for: .milliseconds(30))
            await probe.leave()
            return 1
        }
        let queue = Self.queue(steps, probe: probe)

        queue.add([Self.source("one.wav"), Self.source("two.wav"), Self.source("three.wav")])
        #expect(queue.jobs.map(\.state) == [.converting, .queued, .queued])

        try await Self.waitUntilIdle(queue)

        #expect(probe.maximumConcurrent == 1)
        #expect(queue.jobs.allSatisfy { $0.state == .completed })
        #expect(probe.saved.map(\.sourceFileName) == ["one.wav", "two.wav", "three.wav"])
    }

    @Test func cancellingARunningJobStopsItAndTheNextOneRuns() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.transcribe = { audio, _, _, _ in
            if await audio.lastPathComponent == probe.firstJobAudioName {
                while true { try await Task.sleep(for: .milliseconds(5)) }
            }
            return Self.labelledTranscript
        }
        let queue = Self.queue(steps, probe: probe)
        queue.add([Self.source("long.mp3"), Self.source("short.mp3")])
        let first = try #require(queue.jobs.first?.id)
        probe.firstJobAudioName = "\(first.uuidString).wav"

        try await Self.wait { queue.jobs.first?.state == .transcribing(progress: 0) }
        queue.cancel(first)
        #expect(queue.jobs.first?.isCancelling == true)
        try await Self.waitUntilIdle(queue)

        #expect(queue.jobs.map(\.state) == [.cancelled, .completed])
        #expect(queue.jobs.first?.isCancelling == false)
        #expect(probe.saved.map(\.sourceFileName) == ["short.mp3"])
    }

    @Test func cancellingAQueuedJobSkipsIt() async throws {
        let probe = Probe()
        let queue = Self.queue(Self.steps(probe), probe: probe)

        queue.add([Self.source("first.wav"), Self.source("second.wav")])
        let second = try #require(queue.jobs.last?.id)
        queue.cancel(second)
        try await Self.waitUntilIdle(queue)

        #expect(queue.jobs.map(\.state) == [.completed, .cancelled])
        #expect(probe.saved.map(\.sourceFileName) == ["first.wav"])
    }

    @Test func failedJobCanBeRetried() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.transcribe = { _, _, _, _ in
            if await probe.nextAttempt() == 0 { throw URLError(.notConnectedToInternet) }
            return Self.labelledTranscript
        }
        let queue = Self.queue(steps, probe: probe)

        queue.add([Self.source("call.m4a")])
        try await Self.waitUntilIdle(queue)
        #expect(queue.jobs.first?.state == .failed(.network))

        queue.retry(try #require(queue.jobs.first?.id))
        try await Self.waitUntilIdle(queue)
        #expect(queue.jobs.first?.state == .completed)
        #expect(probe.saved.count == 1)
    }

    @Test func unsupportedFileFailsWithoutRunning() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.convert = { _, _ in
            Issue.record("An unsupported file must not be converted")
            return 0
        }
        let queue = Self.queue(steps, probe: probe)

        queue.add([Self.source("notes.pdf")])
        try await Self.waitUntilIdle(queue)

        #expect(queue.jobs.first?.state == .failed(.unsupportedFile))
    }

    @Test func failedDiarizationStillDeliversTheTranscriptWithoutSpeakers() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.diarize = { _, _, _ in throw FileDiarizer.ModelUnavailable(underlying: URLError(.timedOut)) }
        steps.transcribe = { _, _, turns, _ in
            // Without turns the file is transcribed in plain windows, as with speakers off.
            #expect(turns == nil)
            return Self.twoSpeakerTranscript
        }
        let queue = Self.queue(steps, probe: probe)

        queue.add([Self.source("panel.wav")])
        try await Self.waitUntilIdle(queue)

        let transcript = try #require(queue.jobs.first?.transcript)
        #expect(queue.jobs.first?.state == .completed)
        #expect(transcript.speakerStatus == .failed)
        #expect(transcript.speakers.isEmpty)
        #expect(transcript.segments.allSatisfy { $0.speakerIndex == nil })
    }

    @Test func turningSpeakersOffSkipsDiarization() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.diarize = { _, _, _ in
            Issue.record("Diarization must not run when speakers are off")
            return []
        }
        steps.transcribe = { _, _, turns, _ in
            #expect(turns == nil)
            return Self.twoSpeakerTranscript
        }
        let queue = Self.queue(steps, probe: probe, identifySpeakers: false)

        queue.add([Self.source("lecture.wav")])
        try await Self.waitUntilIdle(queue)

        #expect(queue.jobs.first?.transcript?.speakerStatus == .notRequested)
    }

    @Test func silentFileFailsWithNoSpeech() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.transcribe = { _, _, _, _ in .init(segments: [TranscriptSegment(start: 0, end: 30, text: "  ")], gaps: []) }
        let queue = Self.queue(steps, probe: probe)

        queue.add([Self.source("silence.wav")])
        try await Self.waitUntilIdle(queue)

        #expect(queue.jobs.first?.state == .failed(.noSpeech))
        #expect(probe.saved.isEmpty)
    }

    @Test func missingModelFailsBeforeConverting() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.convert = { _, _ in
            Issue.record("A job without a model must not convert")
            return 0
        }
        let queue = FileTranscriptionQueue(steps: steps, workDirectory: probe.workDirectory) {
            FileTranscriptionOptions(modelName: "", modelDisplayName: "", languageCode: "auto")
        }

        queue.add([Self.source("memo.m4a")])
        try await Self.waitUntilIdle(queue)

        #expect(queue.jobs.first?.state == .failed(.noModelSelected))
    }

    @Test func convertedAudioIsCleanedUpAfterEveryJob() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.transcribe = { _, _, _, _ in throw URLError(.timedOut) }
        let queue = Self.queue(steps, probe: probe)

        queue.add([Self.source("a.wav")])
        try await Self.waitUntilIdle(queue)

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: probe.workDirectory.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func removingAJobKeepsItsHistoryButDropsItFromTheList() async throws {
        let probe = Probe()
        let queue = Self.queue(Self.steps(probe), probe: probe)

        queue.add([Self.source("a.wav"), Self.source("b.wav")])
        try await Self.waitUntilIdle(queue)
        queue.remove(try #require(queue.jobs.first?.id))

        #expect(queue.jobs.map(\.fileName) == ["b.wav"])
        #expect(probe.saved.count == 2)

        queue.clearFinished()
        #expect(queue.jobs.isEmpty)
    }

    @Test func diarizationThatFindsNoSpeechStillTranscribesTheWholeFile() async throws {
        let probe = Probe()
        var steps = Self.steps(probe)
        steps.diarize = { _, _, _ in [] }
        steps.transcribe = { _, _, turns, _ in
            #expect(turns == nil)
            return Self.twoSpeakerTranscript
        }
        let queue = Self.queue(steps, probe: probe)

        queue.add([Self.source("music.wav")])
        try await Self.waitUntilIdle(queue)

        #expect(queue.jobs.first?.state == .completed)
        #expect(queue.jobs.first?.transcript?.speakers.isEmpty == true)
    }

    @Test func optionsFollowTheDefaultsUntilTheUserChangesThem() {
        let probe = Probe()
        var defaultModel = "base"
        let queue = FileTranscriptionQueue(steps: Self.steps(probe), workDirectory: probe.workDirectory) {
            FileTranscriptionOptions(modelName: defaultModel, modelDisplayName: defaultModel, languageCode: "auto")
        }

        #expect(queue.options.modelName == "base")
        defaultModel = "turbo"
        #expect(queue.options.modelName == "turbo")

        queue.options.identifySpeakers = false
        defaultModel = "parakeet"
        #expect(queue.options.modelName == "turbo")
        #expect(queue.options.identifySpeakers == false)
    }

    // MARK: - History

    @Test func savingCreatesTheHistoryRowAudioAndSidecar() throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let transcript = Self.namedTranscript()

        try fixture.history.save(transcript, audio: fixture.makeAudio(), transcriptionDuration: 3)

        let rows = try fixture.context.fetch(FetchDescriptor<Transcription>())
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.id == transcript.transcriptionID)
        #expect(row.text == transcript.plainText)
        #expect(row.duration == 12)
        #expect(row.transcriptionStatus == TranscriptionStatus.completed.rawValue)
        #expect(row.audioFileURL == fixture.store.audioURL(for: transcript.transcriptionID).absoluteString)
        #expect(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: transcript.transcriptionID).path))
        #expect(fixture.store.load(transcript.transcriptionID) == transcript)
        #expect(fixture.didSaveCount == 1)
    }

    @Test func speakerRenamePersistsInTheSidecarAndHistoryText() throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        var transcript = Self.namedTranscript()
        try fixture.history.save(transcript, audio: fixture.makeAudio(), transcriptionDuration: 3)

        transcript.rename(speaker: 0, to: "Dr. Levi")
        fixture.history.update(transcript)

        let stored = try #require(fixture.store.load(transcript.transcriptionID))
        #expect(stored.name(forSpeaker: 0) == "Dr. Levi")
        let row = try #require(try fixture.context.fetch(FetchDescriptor<Transcription>()).first)
        #expect(row.text.hasPrefix("Dr. Levi: "))
    }

    @Test func onlyRowsWithASidecarCanOpenTheFullTranscript() throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let transcript = Self.namedTranscript()
        #expect(!fixture.store.hasTranscript(for: transcript.transcriptionID))

        try fixture.history.save(transcript, audio: fixture.makeAudio(), transcriptionDuration: 3)
        #expect(fixture.store.hasTranscript(for: transcript.transcriptionID))
        #expect(!fixture.store.hasTranscript(for: UUID()))

        fixture.store.remove(transcript.transcriptionID)
        #expect(!fixture.store.hasTranscript(for: transcript.transcriptionID))
    }

    @Test func sidecarIsDeletedWithTheHistoryRowAndNotRecreated() throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        var transcript = Self.namedTranscript()
        try fixture.history.save(transcript, audio: fixture.makeAudio(), transcriptionDuration: 3)
        let sidecar = fixture.store.url(for: transcript.transcriptionID)
        #expect(sidecar.lastPathComponent == FileTranscriptStore.fileName(for: transcript.transcriptionID))
        #expect(sidecar.lastPathComponent.hasSuffix(".segments.json"))

        // What every History delete path does.
        let row = try #require(try fixture.context.fetch(FetchDescriptor<Transcription>()).first)
        fixture.store.remove(row.id)
        fixture.context.delete(row)
        try fixture.context.save()
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        transcript.rename(speaker: 0, to: "Late rename")
        fixture.history.update(transcript)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    // MARK: - Error mapping

    @Test func errorsMapToSpecificReasons() {
        let model = "Whisper Large v3 Turbo"
        #expect(FileTranscriptionError(URLError(.notConnectedToInternet), modelName: model) == .network)
        #expect(FileTranscriptionError(URLError(.timedOut), modelName: model) == .network)
        #expect(FileTranscriptionError(CloudTranscriptionError.networkError(URLError(.cannotFindHost)), modelName: model) == .network)
        #expect(FileTranscriptionError(CloudTranscriptionError.missingAPIKey, modelName: model) == .cloudKeyMissing(model))
        #expect(FileTranscriptionError(CloudTranscriptionError.apiRequestFailed(statusCode: 401, message: "no"), modelName: model) == .cloudKeyMissing(model))
        #expect(FileTranscriptionError(ZermEngineError.modelLoadFailed, modelName: model) == .modelUnavailable(model))
        #expect(FileTranscriptionError(AudioFileConverter.ConversionError.emptyAudio, modelName: model) == .noAudio)
        #expect(FileTranscriptionError(AudioFileConverter.ConversionError.unreadable("x.mov"), modelName: model) == .unreadableFile)
        #expect(FileTranscriptionError(FileTranscriptionError.noSpeech, modelName: model) == .noSpeech)

        let server = FileTranscriptionError(CloudTranscriptionError.apiRequestFailed(statusCode: 500, message: "busy"), modelName: model)
        guard case .failed(let detail) = server else {
            Issue.record("A server error is a plain failure, got \(server)")
            return
        }
        #expect(detail.contains("500"))
    }

    @Test func everyErrorHasAMessage() {
        let errors: [FileTranscriptionError] = [
            .unsupportedFile, .noAudio, .unreadableFile, .noModelSelected, .modelUnavailable("M"),
            .cloudKeyMissing("M"), .network, .noSpeech, .failed("detail")
        ]
        for error in errors {
            #expect(!error.message.isEmpty)
        }
        #expect(FileTranscriptionError.modelUnavailable("Parakeet V3").message.contains("Parakeet V3"))
    }

    // MARK: - Fixtures

    nonisolated private static let twoSpeakerTranscript = WindowedFileTranscriber.Transcript(
        segments: [
            TranscriptSegment(start: 0, end: 5, text: "Welcome to the show"),
            TranscriptSegment(start: 5, end: 10, text: "Thanks for having me")
        ],
        gaps: []
    )

    /// What speaker-by-speaker transcription returns for `twoSpeakerTurns`.
    nonisolated private static let labelledTranscript = WindowedFileTranscriber.Transcript(
        segments: [
            TranscriptSegment(start: 0, end: 5, text: "Welcome to the show", speakerIndex: 4, speakerConfidence: .diarizedTurn),
            TranscriptSegment(start: 5, end: 10, text: "Thanks for having me", speakerIndex: 2, speakerConfidence: .diarizedTurn)
        ],
        gaps: []
    )

    nonisolated private static let twoSpeakerTurns = [
        SpeakerTurn(speakerIndex: 4, start: 0, end: 5),
        SpeakerTurn(speakerIndex: 2, start: 5, end: 10)
    ]

    private static func namedTranscript() -> FileTranscript {
        var transcript = FileTranscript(
            sourceFileName: "interview.m4a",
            duration: 12,
            modelName: "Parakeet V3",
            languageCode: "en",
            speakerStatus: .identified,
            segments: labelledTranscript.segments
        )
        transcript.rename(speaker: 0, to: "Dana")
        transcript.rename(speaker: 1, to: "Noa")
        return transcript
    }

    private static func source(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
    }

    private static func steps(_ probe: Probe) -> FileTranscriptionQueue.Steps {
        FileTranscriptionQueue.Steps(
            convert: { _, _ in 12 },
            transcribe: { _, _, turns, _ in turns == nil ? twoSpeakerTranscript : labelledTranscript },
            diarize: { _, _, _ in twoSpeakerTurns },
            save: { transcript, _, _ in probe.saved.append(transcript) }
        )
    }

    private static func queue(
        _ steps: FileTranscriptionQueue.Steps,
        probe: Probe,
        identifySpeakers: Bool = true,
        speakerCount: SpeakerCount = .automatic
    ) -> FileTranscriptionQueue {
        let queue = FileTranscriptionQueue(steps: steps, workDirectory: probe.workDirectory) {
            FileTranscriptionOptions(
                modelName: "parakeet-tdt-0.6b-v3",
                modelDisplayName: "Parakeet V3",
                languageCode: "auto",
                identifySpeakers: identifySpeakers,
                speakerCount: speakerCount
            )
        }
        probe.queue = queue
        return queue
    }

    private static func waitUntilIdle(_ queue: FileTranscriptionQueue) async throws {
        try await wait { queue.jobs.allSatisfy { $0.state.isFinished } }
        // Let the finished task release the queue before the next command.
        try await Task.sleep(for: .milliseconds(20))
    }

    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the queue")
    }
}

/// Observes the steps from inside the queue.
@MainActor
private final class Probe {
    weak var queue: FileTranscriptionQueue?
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zerm-file-queue-\(UUID().uuidString)", isDirectory: true)
    var states: [FileTranscriptionQueue.Job.State] = []
    var saved: [FileTranscript] = []
    var firstJobAudioName = ""
    private(set) var maximumConcurrent = 0
    private var concurrent = 0
    private var attempts = 0

    func recordState() {
        if let state = queue?.jobs.first(where: { !$0.state.isFinished })?.state {
            states.append(state)
        }
    }

    func enter() {
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
    }

    func leave() {
        concurrent -= 1
    }

    func nextAttempt() -> Int {
        defer { attempts += 1 }
        return attempts
    }
}

@MainActor
private final class HistoryFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zerm-file-history-\(UUID().uuidString)", isDirectory: true)
    let context: ModelContext
    let store: FileTranscriptStore
    var history: FileTranscriptionHistory!
    var didSaveCount = 0

    init() throws {
        let container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        store = FileTranscriptStore(directory: directory.appendingPathComponent("Recordings", isDirectory: true))
        history = FileTranscriptionHistory(modelContext: context, store: store) { [weak self] _ in
            self?.didSaveCount += 1
        }
    }

    func makeAudio() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("converted.wav")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
