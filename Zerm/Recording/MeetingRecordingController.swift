import Combine
import Foundation
import OSLog

/// Application-scoped coordinator for capture and durable post-processing.
///
/// The app owns one instance for its lifetime. Views observe it; they do not own recording.
/// Every asynchronous callback is checked against the immutable session ID before it can mutate
/// current state, preventing a late result from one meeting appearing in the next.
@MainActor
final class MeetingRecordingController: ObservableObject {

    @Published private(set) var segments: [MeetingTranscriber.Segment] = []
    @Published private(set) var lastRecording: MeetingRecordingSession.Recording?
    @Published private(set) var errorMessage: String?
    /// True while the post-meeting transcription pass is running.
    ///
    /// Capture itself no longer transcribes (#310), so this tracks the `processing` phase — the
    /// one place model work happens — rather than a live pass competing with the audio thread.
    var isTranscribing: Bool { lifecycle.phase == .processing }
    @Published private(set) var lifecycle: MeetingRecordingLifecycle = .idle
    @Published private(set) var transcriptionSnapshot: MeetingTranscriptionSnapshot?
    @Published private(set) var sourceHealth: [MeetingAudioSource: MeetingSourceHealth] = [:]
    @Published private(set) var processingProgress: Double = 0

    @Published private(set) var speakerTurns: [MeetingDiarizer.Turn] = []
    @Published private(set) var isPreparingDiarizer = false

    @Published private(set) var summary: MeetingSummarizer.Result?
    @Published private(set) var summarySnapshot: MeetingSummarySnapshot?
    @Published private(set) var isSummarising = false
    @Published private(set) var summaryError: String?
    @Published private(set) var isLocalSummaryAvailable: Bool?

    var activeSessionID: UUID? { lifecycle.sessionID }
    var isRecording: Bool { lifecycle.phase == .capturing }
    var transcript: String { segments.map(\.text).joined(separator: " ") }

    var speakerCount: Int {
        Set(speakerTurns.map { "\($0.source.rawValue):\($0.speakerIndex)" }).count
    }

    /// Synchronous safety boundary invoked on MainActor immediately before any capture backend
    /// opens. The app wires this directly to Read Aloud shutdown; notification delivery is too
    /// late because Combine/run-loop hops can let synthesized speech bleed into the first frames.
    var onWillStartCapture: (() -> Void)?

    let session: MeetingRecordingSession

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingRecordingController")
    private weak var engine: ZermEngine?
    private var cancellables = Set<AnyCancellable>()
    private var diarizers: [MeetingAudioSource: MeetingDiarizer] = [:]
    private var turnsBySource: [MeetingAudioSource: [MeetingDiarizer.Turn]] = [:]
    private var activeModel: (any TranscriptionModel)?
    private var activeRequest: MeetingRecordingRequest?
    private var processingIssues: [MeetingRecordingIssue] = []
    private var unresolvedGaps: [MeetingTranscriber.Gap] = []
    private var transcriptionCoverageStrategy: MeetingRecordingStore.Manifest.TranscriptionCoverageStrategy?
    private var stopTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private let nativeAppleSupportedLocales: @MainActor () async -> [String]

    init(
        engine: ZermEngine?,
        session: MeetingRecordingSession? = nil,
        nativeAppleSupportedLocales: @escaping @MainActor () async -> [String] = {
            await NativeAppleTranscriptionService.meetingSupportedLocaleIdentifiers()
        }
    ) {
        let session = session ?? MeetingRecordingSession()
        self.engine = engine
        self.session = session
        self.nativeAppleSupportedLocales = nativeAppleSupportedLocales
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    #if DEBUG
    func applyTurnsForTesting(_ turns: [MeetingDiarizer.Turn]) {
        speakerTurns = turns
    }
    #endif

    func speakerLabel(for segment: MeetingTranscriber.Segment) -> String? {
        if let speaker = segment.assignedSpeakerIndex {
            let format = segment.source == .systemAudio
                ? String(localized: "Remote Speaker %lld")
                : String(localized: "Speaker %lld")
            return String.localizedStringWithFormat(format, Int64(speaker + 1))
        }
        var overlapBySpeaker: [Int: TimeInterval] = [:]
        for turn in speakerTurns where turn.source == segment.source {
            let overlap = min(segment.end, turn.end) - max(segment.start, turn.start)
            guard overlap > 0 else { continue }
            overlapBySpeaker[turn.speakerIndex, default: 0] += overlap
        }
        guard let best = overlapBySpeaker.max(by: { $0.value < $1.value })?.key else { return nil }
        let format = segment.source == .systemAudio
            ? String(localized: "Remote Speaker %lld")
            : String(localized: "Speaker %lld")
        return String.localizedStringWithFormat(format, Int64(best + 1))
    }

    // MARK: - Start

    /// Compatibility adapter. New UI should pass an explicit capture target in a request.
    func start(
        sources: MeetingRecordingSession.Sources = .all,
        identifySpeakers: Bool = true
    ) {
        start(request: .init(
            sources: sources,
            target: .allSystemAudio,
            identifySpeakers: identifySpeakers
        ))
    }

    func start(request: MeetingRecordingRequest) {
        guard canStart else {
            errorMessage = String(localized: "Finish the current meeting before starting another one.")
            return
        }

        let sessionID = UUID()
        let preflightSummarySnapshot = summarySnapshot
        let preflightSummaryAvailability = isLocalSummaryAvailable
        resetForStart()
        summarySnapshot = preflightSummarySnapshot
        isLocalSummaryAvailable = preflightSummaryAvailability
        activeRequest = request
        transition(to: .init(phase: .preflighting, sessionID: sessionID, pendingJobs: 0, issues: []))

        // A model is needed to transcribe after Stop, not to capture. Refusing to start without
        // one would throw away audio the user cannot re-record.
        let model = engine?.transcriptionModelManager.currentTranscriptionModel
        activeModel = model
        if let model {
            let requestedLanguageCode = LanguagePreference.selectedCode()
            if model.provider == .nativeApple {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let snapshot = try await self.resolvedTranscriptionSnapshot(
                            for: model,
                            requestedLanguageCode: requestedLanguageCode
                        )
                        guard self.activeSessionID == sessionID else { return }
                        self.transcriptionSnapshot = snapshot
                        self.beginCapture(request: request, sessionID: sessionID)
                    } catch {
                        guard self.activeSessionID == sessionID else { return }
                        self.fail(sessionID: sessionID, message: error.localizedDescription)
                    }
                }
                return
            }
            transcriptionSnapshot = MeetingTranscriptionSnapshot(
                model: model,
                languageCode: requestedLanguageCode
            )
        }

        beginCapture(request: request, sessionID: sessionID)
    }

    private func beginCapture(request: MeetingRecordingRequest, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }

        prepareDiarizers(for: request, sessionID: sessionID)

        // Capture runs no model work. Transcription happens once, after Stop, over the saved
        // tracks — see `beginProcessing`. Running it live competed with the audio thread for CPU
        // and, on the local path, was thrown away by the canonical pass anyway.
        let diarizers = diarizers
        session.onAudioChunk = { chunk in
            guard chunk.sessionID == sessionID else { return }
            diarizers[chunk.source]?.append(chunk)
        }
        session.onSourceHealth = { [weak self] source, health in
            guard self?.activeSessionID == sessionID else { return }
            self?.sourceHealth[source] = health
        }

        do {
            onWillStartCapture?()
            try session.start(
                sources: request.sources,
                target: request.target,
                sessionID: sessionID,
                transcriptionSnapshot: transcriptionSnapshot
            )
            sourceHealth = session.sourceHealth
            transition(to: .init(phase: .capturing, sessionID: sessionID, pendingJobs: 0, issues: []))
        } catch {
            tearDownPipelines(cancel: true)
            NotificationCenter.default.post(
                name: .meetingRecordingDidStop,
                object: self,
                userInfo: [MeetingRecordingNotificationKey.sessionID: sessionID.uuidString]
            )
            fail(sessionID: sessionID, message: error.localizedDescription)
            logger.error("Meeting recording failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolvedTranscriptionSnapshot(
        for model: any TranscriptionModel,
        requestedLanguageCode: String
    ) async throws -> MeetingTranscriptionSnapshot {
        guard model.provider == .nativeApple else {
            return MeetingTranscriptionSnapshot(
                model: model,
                languageCode: requestedLanguageCode
            )
        }
        let supported = await nativeAppleSupportedLocales()
        guard let resolved = MeetingLanguageResolver.nativeAppleMeetingLocaleCode(
            requestedCode: requestedLanguageCode,
            supportedIdentifiers: supported
        ) else {
            throw NativeAppleTranscriptionService.ServiceError.localeNotSupported
        }
        return MeetingTranscriptionSnapshot(model: model, resolvedLanguageCode: resolved)
    }

    private var canStart: Bool {
        switch lifecycle.phase {
        case .idle, .ready, .partial, .failed:
            return true
        case .preflighting, .capturing, .stopping, .processing:
            return false
        }
    }

    private func resetForStart() {
        summaryTask?.cancel()
        summaryTask = nil
        activeModel = nil
        activeRequest = nil
        errorMessage = nil
        segments = []
        speakerTurns = []
        turnsBySource = [:]
        sourceHealth = [:]
        lastRecording = nil
        summary = nil
        summarySnapshot = nil
        summaryError = nil
        isLocalSummaryAvailable = nil
        transcriptionSnapshot = nil
        processingProgress = 0
        processingIssues = []
        unresolvedGaps = []
        transcriptionCoverageStrategy = nil
    }

    private func prepareDiarizers(for request: MeetingRecordingRequest, sessionID: UUID) {
        guard request.identifySpeakers else { return }
        for source in sources(in: request.sources) {
            let diarizer = MeetingDiarizer(source: source)
            diarizer.onTurns = { [weak self] turns in
                guard let self, self.activeSessionID == sessionID else { return }
                self.turnsBySource[source] = turns
                self.speakerTurns = self.turnsBySource.values.flatMap { $0 }.sorted {
                    if $0.start == $1.start { return $0.source.rawValue < $1.source.rawValue }
                    return $0.start < $1.start
                }
            }
            diarizers[source] = diarizer
        }

        let values = Array(diarizers.values)
        guard !values.isEmpty else { return }
        isPreparingDiarizer = true
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for diarizer in values {
                    group.addTask { await diarizer.prepare() }
                }
            }
            guard let self, self.activeSessionID == sessionID else { return }
            self.isPreparingDiarizer = false
        }
    }

    // MARK: - Stop and processing

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard lifecycle.phase == .capturing, let sessionID = activeSessionID else { return }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performStop(sessionID: sessionID)
        }
        stopTask = task
        await task.value
        if activeSessionID == sessionID { stopTask = nil }
    }

    /// The one public end-of-meeting operation. Repeated callers await the same canonical work,
    /// and summary can only begin after that work reaches a terminal state for the same session.
    func stopAndSummarise(ifRequested shouldSummarise: Bool) async {
        await stop()
        guard shouldSummarise else { return }
        await summarise()
    }

    private func performStop(sessionID: UUID) async {
        guard lifecycle.phase == .capturing, activeSessionID == sessionID else { return }
        transition(to: .init(phase: .stopping, sessionID: sessionID, pendingJobs: 0, issues: lifecycle.issues))

        let recording = session.stop()
        session.onAudioChunk = nil
        session.onSourceHealth = nil
        lastRecording = recording

        let activeDiarizers = Array(diarizers.values)
        for diarizer in activeDiarizers {
            if !(await diarizer.finishAndWait()) {
                addProcessingIssue(
                    code: "diarization-finish-timeout",
                    message: String(localized: "Speaker identification did not finish in time. The recording and transcript were preserved.")
                )
            }
        }
        diarizers = [:]
        isPreparingDiarizer = false

        guard activeSessionID == sessionID, let recording else {
            fail(
                sessionID: sessionID,
                message: String(localized: "The recording ended without a recoverable session.")
            )
            return
        }

        let tracks = trackJobs(for: recording)
        let transcriptionJobs = activeModel == nil ? 0 : tracks.count
        transition(to: .init(
            phase: .processing,
            sessionID: sessionID,
            pendingJobs: transcriptionJobs,
            issues: combinedIssues
        ))

        if let model = activeModel, let snapshot = transcriptionSnapshot {
            // One pass over each saved track, whatever the route. There is no live coverage to
            // reconcile any more: capture records audio only.
            transcriptionCoverageStrategy = snapshot.route == .local
                ? .canonicalLocalTracks
                : .canonicalCloudTracks
            var canonical: [MeetingTranscriber.Segment] = []
            for (index, track) in tracks.enumerated() {
                let retryRanges: [ClosedRange<TimeInterval>]? = nil
                let engine = self.engine
                let transcriber = MeetingTranscriber(source: track.source) { url in
                    try await Self.transcribe(
                        url: url,
                        engine: engine,
                        model: model,
                        languageCode: snapshot.languageCode
                    )
                }
                transcriber.onGap = { [weak self] gap in
                    self?.unresolvedGaps.append(gap)
                    self?.addProcessingIssue(
                        source: gap.source,
                        code: "post-transcription-gap",
                        message: gap.reason
                    )
                }
                do {
                    let trackSegments = try await transcriber.transcribeFile(
                        track.url,
                        source: track.source,
                        startOffset: track.startOffset,
                        clockAnchors: track.clockAnchors,
                        meetingRanges: retryRanges
                    ) { [weak self] fraction in
                        await MainActor.run {
                            self?.processingProgress = (
                                Double(index) + fraction
                            ) / Double(max(1, tracks.count))
                        }
                    }
                    if let retryRanges {
                        canonical.removeAll { segment in
                            segment.source == track.source
                                && retryRanges.contains { $0.overlaps(segment.start...segment.end) }
                        }
                    }
                    canonical.append(contentsOf: trackSegments)
                } catch {
                    unresolvedGaps.append(.init(
                        source: track.source,
                        start: track.startOffset,
                        end: track.startOffset + recording.duration,
                        reason: error.localizedDescription
                    ))
                    addProcessingIssue(
                        source: track.source,
                        code: "post-transcription-failed",
                        message: error.localizedDescription
                    )
                }
                transition(to: .init(
                    phase: .processing,
                    sessionID: sessionID,
                    pendingJobs: max(0, tracks.count - index - 1),
                    issues: combinedIssues
                ))
            }
            segments = canonical
            sortSegments()
        }

        if activeRequest?.identifySpeakers == true {
            var offlineTurns: [MeetingDiarizer.Turn] = []
            for track in tracks {
                let diarizer = MeetingDiarizer(source: track.source)
                Task { await diarizer.prepare() }
                guard await diarizer.waitUntilPrepared(timeout: 15) else {
                    addProcessingIssue(
                        source: track.source,
                        code: "offline-diarization-timeout",
                        message: String(localized: "Canonical speaker identification was unavailable; transcript text was preserved with uncertain speakers.")
                    )
                    continue
                }
                do {
                    offlineTurns.append(contentsOf: try await diarizer.diarizeFile(
                        track.url,
                        startOffset: track.startOffset,
                        clockAnchors: track.clockAnchors
                    ))
                } catch {
                    addProcessingIssue(
                        source: track.source,
                        code: "offline-diarization-failed",
                        message: error.localizedDescription
                    )
                }
                diarizer.finish()
            }
            if !offlineTurns.isEmpty {
                speakerTurns = offlineTurns.sorted { $0.start < $1.start }
                processingIssues.removeAll { $0.code == "diarization-finish-timeout" }
            }
            segments = MeetingSpeakerAttributor.split(segments, using: speakerTurns)
            sortSegments()
        }

        processingProgress = 1
        if !persist(recording) {
            addProcessingIssue(
                code: "sidecar-write-failed",
                message: String(localized: "The audio was retained, but the transcript sidecar could not be saved. Retry processing from the library.")
            )
        }
        let finalPhase: MeetingRecordingLifecycle.Phase = combinedIssues.contains {
            $0.severity == .error
        } ? .partial : .ready
        if !updateManifest(for: recording, phase: finalPhase) {
            addProcessingIssue(
                code: "manifest-update-failed",
                message: String(localized: "The audio was retained, but processing status could not be saved. Retry from the library.")
            )
        }
        let persistedPhase: MeetingRecordingLifecycle.Phase = combinedIssues.contains {
            $0.severity == .error
        } ? .partial : .ready
        transition(to: .init(
            phase: persistedPhase,
            sessionID: sessionID,
            pendingJobs: 0,
            issues: combinedIssues
        ))
        logger.notice("Meeting saved to \(recording.folder.lastPathComponent, privacy: .public)")
    }

    /// Runs the same durable transcription and diarization pipeline for an imported or recovered
    /// item. Import is therefore a valid meeting session, not merely a converted audio file.
    func process(_ item: MeetingRecordingStore.Item, identifySpeakers: Bool = true) async {
        guard canStart else {
            errorMessage = String(localized: "Finish the current meeting before processing another recording.")
            return
        }
        guard let model = engine?.transcriptionModelManager.currentTranscriptionModel else {
            errorMessage = String(localized: "Choose a dictation model before processing this recording.")
            return
        }
        let resolvedSnapshot: MeetingTranscriptionSnapshot
        let requestedLanguageCode = LanguagePreference.selectedCode()
        do {
            resolvedSnapshot = try await resolvedTranscriptionSnapshot(
                for: model,
                requestedLanguageCode: requestedLanguageCode
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let sessionID = item.sessionID ?? UUID()
        let retainedSummary = item.summary
        let retainedSummarySnapshot = MeetingRecordingStore.readManifest(in: item.folder)?.summarySnapshot
        resetForStart()
        summary = retainedSummary
        summarySnapshot = retainedSummarySnapshot
        activeModel = model
        transcriptionSnapshot = resolvedSnapshot
        transition(to: .init(
            phase: .preflighting,
            sessionID: sessionID,
            pendingJobs: 0,
            issues: []
        ))
        let manifest = MeetingRecordingStore.readManifest(in: item.folder)
        activeRequest = .init(
            sources: [.microphone, .systemAudio],
            target: manifest?.captureTarget ?? .allSystemAudio,
            identifySpeakers: identifySpeakers
        )
        var jobs: [TrackJob] = []
        if let url = item.microphoneTrack {
            let track = manifest?.tracks.first { $0.fileName == url.lastPathComponent }
            jobs.append(.init(
                source: track?.source ?? .microphone,
                url: url,
                startOffset: track?.startOffset ?? 0,
                duration: max(0, track?.duration ?? item.duration),
                clockAnchors: track?.clockAnchors ?? []
            ))
        }
        if let url = item.systemAudioTrack {
            let track = manifest?.tracks.first { $0.fileName == url.lastPathComponent }
            jobs.append(.init(
                source: track?.source ?? .systemAudio,
                url: url,
                startOffset: track?.startOffset ?? 0,
                duration: max(0, track?.duration ?? item.duration),
                clockAnchors: track?.clockAnchors ?? []
            ))
        }

        transition(to: .init(
            phase: .processing,
            sessionID: sessionID,
            pendingJobs: jobs.count,
            issues: []
        ))

        let snapshot = transcriptionSnapshot!
        transcriptionCoverageStrategy = snapshot.route == .local
            ? .canonicalLocalTracks
            : .canonicalCloudTracks
        var canonical: [MeetingTranscriber.Segment] = []
        var recoveredTurns: [MeetingDiarizer.Turn] = []
        for (index, job) in jobs.enumerated() {
            let engine = self.engine
            let transcriber = MeetingTranscriber(source: job.source) { url in
                try await Self.transcribe(
                    url: url,
                    engine: engine,
                    model: model,
                    languageCode: snapshot.languageCode
                )
            }
            transcriber.onGap = { [weak self] gap in
                self?.unresolvedGaps.append(gap)
                self?.addProcessingIssue(
                    source: gap.source,
                    code: "import-transcription-gap",
                    message: gap.reason
                )
            }
            do {
                canonical.append(contentsOf: try await transcriber.transcribeFile(
                    job.url,
                    source: job.source,
                    startOffset: job.startOffset,
                    clockAnchors: job.clockAnchors
                ))
            } catch {
                addProcessingIssue(
                    source: job.source,
                    code: "import-transcription-failed",
                    message: error.localizedDescription
                )
            }

            if identifySpeakers {
                let diarizer = MeetingDiarizer(source: job.source)
                Task { await diarizer.prepare() }
                guard await diarizer.waitUntilPrepared(timeout: 15) else {
                    addProcessingIssue(
                        source: job.source,
                        code: "import-diarization-timeout",
                        message: String(localized: "Speaker identification did not become ready in time. Transcript text was preserved.")
                    )
                    processingProgress = Double(index + 1) / Double(max(1, jobs.count))
                    continue
                }
                do {
                    recoveredTurns.append(contentsOf: try await diarizer.diarizeFile(
                        job.url,
                        startOffset: job.startOffset,
                        clockAnchors: job.clockAnchors
                    ))
                } catch {
                    addProcessingIssue(
                        source: job.source,
                        code: "import-diarization-failed",
                        message: error.localizedDescription
                    )
                }
                diarizer.finish()
            }
            processingProgress = Double(index + 1) / Double(max(1, jobs.count))
            transition(to: .init(
                phase: .processing,
                sessionID: sessionID,
                pendingJobs: max(0, jobs.count - index - 1),
                issues: processingIssues
            ))
        }

        speakerTurns = recoveredTurns.sorted { $0.start < $1.start }
        segments = identifySpeakers
            ? MeetingSpeakerAttributor.split(canonical, using: speakerTurns)
            : canonical
        sortSegments()
        let store = MeetingRecordingStore()
        let sidecarSaved = store.writeSidecar(
            into: item.folder,
            startedAt: item.startedAt,
            duration: item.duration,
            segments: segments,
            speakerLabel: { [weak self] segment in self?.speakerLabel(for: segment) },
            speakerCount: speakerCount,
            summary: retainedSummary
        )
        if !sidecarSaved {
            addProcessingIssue(
                code: "sidecar-write-failed",
                message: String(localized: "The audio was retained, but the transcript sidecar could not be saved. Retry processing from the library.")
            )
        }

        var updated = MeetingRecordingStore.readManifest(in: item.folder) ?? .init(
            sessionID: sessionID,
            startedAt: item.startedAt,
            endedAt: Date(),
            status: .processing,
            duration: item.duration,
            captureTarget: .allSystemAudio,
            requestedSources: jobs.map(\.source),
            tracks: jobs.map { job in
                .init(
                    source: job.source,
                    fileName: job.url.lastPathComponent,
                    startOffset: job.startOffset,
                    duration: item.duration,
                    frames: 0,
                    clockAnchors: job.clockAnchors
                )
            },
            importedFileName: item.id
        )
        updated.status = processingIssues.contains { $0.severity == .error } ? .partial : .ready
        updated.transcriptionSnapshot = snapshot
        updated.transcriptionStatus = unresolvedGaps.isEmpty
            && !processingIssues.contains { $0.code.contains("transcription") }
            ? .complete : .failed
        updated.diarizationStatus = identifySpeakers
            ? (processingIssues.contains { $0.code.contains("diarization") } ? .failed : .complete)
            : .notRequested
        let replaceablePrefixes = ["import-", "post-transcription-", "offline-diarization-", "sidecar-", "manifest-update-"]
        updated.issues.removeAll { issue in
            replaceablePrefixes.contains { issue.code.hasPrefix($0) }
        }
        updated.issues.append(contentsOf: processingIssues)
        updated.transcriptionGaps = unresolvedGaps
        updated.transcriptionCoverageStrategy = transcriptionCoverageStrategy
        do {
            try MeetingRecordingStore.writeManifest(updated, into: item.folder)
        } catch {
            addProcessingIssue(
                code: "manifest-update-failed",
                message: String(localized: "The audio was retained, but processing status could not be saved. Retry from the library.")
            )
        }

        lastRecording = .init(
            id: sessionID,
            folder: item.folder,
            startedAt: item.startedAt,
            duration: item.duration,
            microphoneTrack: jobs.first { $0.source == .microphone || $0.source == .imported }?.url,
            systemAudioTrack: jobs.first { $0.source == .systemAudio }?.url
        )
        let phase: MeetingRecordingLifecycle.Phase = processingIssues.contains {
            $0.severity == .error
        } ? .partial : .ready
        transition(to: .init(
            phase: phase,
            sessionID: sessionID,
            pendingJobs: 0,
            issues: processingIssues
        ))
    }

    /// Synchronous shutdown boundary used before the app's existing forced process exit.
    func prepareForTermination() {
        guard [.preflighting, .capturing, .stopping, .processing].contains(lifecycle.phase) else { return }
        let id = activeSessionID
        stopTask?.cancel()
        summaryTask?.cancel()
        diarizers.values.forEach { $0.finish() }
        diarizers = [:]
        session.onAudioChunk = nil
        session.onSourceHealth = nil
        if lifecycle.phase == .capturing || lifecycle.phase == .stopping {
            lastRecording = session.prepareForTermination()
        } else if let recording = lastRecording,
                  var manifest = MeetingRecordingStore.readManifest(in: recording.folder) {
            manifest.status = .interrupted
            manifest.issues.append(.init(
                severity: .warning,
                code: "processing-interrupted",
                message: String(localized: "Meeting processing was interrupted when Zerm closed.")
            ))
            do {
                try MeetingRecordingStore.writeManifest(manifest, into: recording.folder)
            } catch {
                // Termination cannot await a retry, but persistence failures must remain visible
                // in diagnostics instead of being silently discarded.
                logger.error("Could not persist interrupted meeting manifest: \(error.localizedDescription, privacy: .public)")
            }
        }
        transition(to: .init(
            phase: .partial,
            sessionID: id,
            pendingJobs: 0,
            issues: combinedIssues + [
                .init(
                    severity: .warning,
                    code: "processing-interrupted",
                    message: String(localized: "Meeting processing was interrupted when Zerm closed.")
                )
            ]
        ))
    }

    // MARK: - Summary

    @discardableResult
    func checkLocalSummaryAvailability() async -> Bool {
        let snapshot = MeetingSummarySnapshot.configuredOllama
        summarySnapshot = snapshot
        let available: Bool
        if let enhancementService = engine?.enhancementService {
            available = await enhancementService.isMeetingSummaryAvailable(snapshot: snapshot)
        } else {
            available = false
        }
        isLocalSummaryAvailable = available
        return available
    }

    func summarise() async {
        if let summaryTask {
            await summaryTask.value
            return
        }
        guard let sessionID = lifecycle.sessionID,
              [.ready, .partial].contains(lifecycle.phase),
              lastRecording?.id == sessionID,
              !segments.isEmpty else { return }

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performSummary(sessionID: sessionID)
        }
        summaryTask = task
        await task.value
        if lifecycle.sessionID == sessionID { summaryTask = nil }
    }

    private func performSummary(sessionID: UUID) async {
        guard lifecycle.sessionID == sessionID,
              [.ready, .partial].contains(lifecycle.phase),
              let recording = lastRecording,
              recording.id == sessionID else { return }
        let terminalPhase = lifecycle.phase
        let lines = segments.map { segment in
            MeetingRecordingStore.Sidecar.Line(
                source: segment.source,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speaker: speakerLabel(for: segment)
            )
        }
        let engine = self.engine
        transition(to: .init(
            phase: .processing,
            sessionID: sessionID,
            pendingJobs: 1,
            issues: lifecycle.issues
        ))
        isSummarising = true
        summaryError = nil
        defer {
            isSummarising = false
            if lifecycle.sessionID == sessionID, lifecycle.phase == .processing {
                transition(to: .init(
                    phase: terminalPhase,
                    sessionID: sessionID,
                    pendingJobs: 0,
                    issues: combinedIssues
                ))
            }
        }

        let snapshot = MeetingSummarySnapshot.configuredOllama
        summarySnapshot = snapshot
        let summaryAvailable: Bool
        if let enhancementService = engine?.enhancementService {
            summaryAvailable = await enhancementService.isMeetingSummaryAvailable(snapshot: snapshot)
        } else {
            summaryAvailable = false
        }
        isLocalSummaryAvailable = summaryAvailable
        guard summaryAvailable else {
            guard !Task.isCancelled, lifecycle.sessionID == sessionID else { return }
            summaryError = String(localized: "A local meeting-summary model is not available. Start Ollama and install the selected model, then try again.")
            _ = updateSummaryManifest(for: recording, status: .unavailable, snapshot: snapshot)
            return
        }
        guard !Task.isCancelled, lifecycle.sessionID == sessionID else { return }
        _ = updateSummaryManifest(for: recording, status: .running, snapshot: snapshot)
        let summariser = MeetingSummarizer { system, text in
            try await Self.complete(systemPrompt: system, text: text, engine: engine)
        }
        do {
            let result = try await summariser.summarize(lines: lines)
            guard !Task.isCancelled, lifecycle.sessionID == sessionID else { return }
            summary = result
            if persist(recording) {
                _ = updateSummaryManifest(for: recording, status: .complete, snapshot: snapshot)
            } else {
                _ = updateSummaryManifest(for: recording, status: .failed, snapshot: snapshot)
            }
        } catch {
            guard !Task.isCancelled, lifecycle.sessionID == sessionID else { return }
            summaryError = error.localizedDescription
            _ = updateSummaryManifest(for: recording, status: .failed, snapshot: snapshot)
            logger.error("Meeting summary failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Persistence and helpers

    private struct TrackJob {
        let source: MeetingAudioSource
        let url: URL
        let startOffset: TimeInterval
        let duration: TimeInterval
        let clockAnchors: [MeetingClockAnchor]
    }

    private func trackJobs(for recording: MeetingRecordingSession.Recording) -> [TrackJob] {
        let manifest = MeetingRecordingStore.readManifest(in: recording.folder)
        func offset(for source: MeetingAudioSource) -> TimeInterval {
            manifest?.tracks.first { $0.source == source }?.startOffset ?? 0
        }
        var result: [TrackJob] = []
        if let url = recording.microphoneTrack,
           FileManager.default.fileExists(atPath: url.path) {
            let track = manifest?.tracks.first { $0.source == .microphone }
            result.append(.init(
                source: .microphone,
                url: url,
                startOffset: offset(for: .microphone),
                duration: max(0, track?.duration ?? recording.duration),
                clockAnchors: track?.clockAnchors ?? []
            ))
        }
        if let url = recording.systemAudioTrack,
           FileManager.default.fileExists(atPath: url.path) {
            let track = manifest?.tracks.first { $0.source == .systemAudio }
            result.append(.init(
                source: .systemAudio,
                url: url,
                startOffset: offset(for: .systemAudio),
                duration: max(0, track?.duration ?? recording.duration),
                clockAnchors: track?.clockAnchors ?? []
            ))
        }
        return result
    }

    @discardableResult
    private func persist(_ recording: MeetingRecordingSession.Recording) -> Bool {
        let store = MeetingRecordingStore()
        let saved = store.writeSidecar(
            into: recording.folder,
            startedAt: recording.startedAt,
            duration: recording.duration,
            segments: segments,
            speakerLabel: { [weak self] segment in self?.speakerLabel(for: segment) },
            speakerCount: speakerCount,
            summary: summary
        )
        if saved { session.resolveIssue(code: "transcript-journal-write-failed") }
        return saved
    }

    @discardableResult
    private func updateManifest(
        for recording: MeetingRecordingSession.Recording,
        phase: MeetingRecordingLifecycle.Phase
    ) -> Bool {
        guard var manifest = MeetingRecordingStore.readManifest(in: recording.folder) else { return false }
        manifest.status = phase == .ready ? .ready : .partial
        manifest.transcriptionStatus = activeModel == nil
            ? .notRequested
            : (unresolvedGaps.isEmpty ? .complete : .failed)
        manifest.diarizationStatus = activeRequest?.identifySpeakers == true
            ? (speakerTurns.isEmpty ? .failed : .complete)
            : .notRequested
        manifest.sourceHealth = Dictionary(
            uniqueKeysWithValues: sourceHealth.map { ($0.key.rawValue, $0.value) }
        )
        manifest.issues = combinedIssues
        manifest.transcriptionGaps = unresolvedGaps
        manifest.transcriptionCoverageStrategy = transcriptionCoverageStrategy
        manifest.summarySnapshot = summarySnapshot
        if summary != nil { manifest.summaryStatus = .complete }
        do {
            try MeetingRecordingStore.writeManifest(manifest, into: recording.folder)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func updateSummaryManifest(
        for recording: MeetingRecordingSession.Recording,
        status: MeetingRecordingStore.Manifest.JobStatus,
        snapshot: MeetingSummarySnapshot
    ) -> Bool {
        guard var manifest = MeetingRecordingStore.readManifest(in: recording.folder) else { return false }
        manifest.summarySnapshot = snapshot
        manifest.summaryStatus = status
        do {
            try MeetingRecordingStore.writeManifest(manifest, into: recording.folder)
            return true
        } catch {
            return false
        }
    }

    private var combinedIssues: [MeetingRecordingIssue] {
        session.issues + processingIssues
    }

    private func addProcessingIssue(
        source: MeetingAudioSource? = nil,
        code: String,
        message: String
    ) {
        guard !processingIssues.contains(where: { $0.source == source && $0.code == code && $0.message == message }) else {
            return
        }
        processingIssues.append(.init(
            source: source,
            severity: .error,
            code: code,
            message: message
        ))
    }

    private func sortSegments() {
        segments.sort {
            if $0.start == $1.start { return $0.source.rawValue < $1.source.rawValue }
            return $0.start < $1.start
        }
    }

    private static func mergedRanges(
        _ ranges: [ClosedRange<TimeInterval>]
    ) -> [ClosedRange<TimeInterval>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<TimeInterval>] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    static func uncoveredRanges(
        within fullRange: ClosedRange<TimeInterval>,
        coveredBy ranges: [ClosedRange<TimeInterval>]
    ) -> [ClosedRange<TimeInterval>] {
        guard fullRange.upperBound > fullRange.lowerBound else { return [] }
        let clipped = ranges.compactMap { range -> ClosedRange<TimeInterval>? in
            let lower = max(fullRange.lowerBound, range.lowerBound)
            let upper = min(fullRange.upperBound, range.upperBound)
            return upper > lower ? lower...upper : nil
        }
        let covered = mergedRanges(clipped)
        var cursor = fullRange.lowerBound
        var missing: [ClosedRange<TimeInterval>] = []
        for range in covered {
            if range.lowerBound > cursor + 0.001 {
                missing.append(cursor...range.lowerBound)
            }
            cursor = max(cursor, range.upperBound)
            if cursor >= fullRange.upperBound { break }
        }
        if cursor < fullRange.upperBound - 0.001 {
            missing.append(cursor...fullRange.upperBound)
        }
        return missing
    }

    private func sources(in sources: MeetingRecordingSession.Sources) -> [MeetingAudioSource] {
        var result: [MeetingAudioSource] = []
        if sources.contains(.microphone) { result.append(.microphone) }
        if sources.contains(.systemAudio) { result.append(.systemAudio) }
        return result
    }

    private func transition(to next: MeetingRecordingLifecycle) {
        let allowed: Bool
        switch (lifecycle.phase, next.phase) {
        case (.idle, .preflighting),
             (.ready, .preflighting),
             (.partial, .preflighting),
             (.failed, .preflighting),
             (.preflighting, .capturing),
             (.preflighting, .processing),
             (.preflighting, .failed),
             (.capturing, .stopping),
             (.capturing, .partial),
             (.stopping, .processing),
             (.stopping, .failed),
             (.stopping, .partial),
             (.processing, .processing),
             (.processing, .ready),
             (.processing, .partial):
            allowed = true
        default:
            allowed = lifecycle.phase == next.phase && lifecycle.sessionID == next.sessionID
        }
        guard allowed else {
            logger.fault("Rejected meeting state transition \(self.lifecycle.phase.rawValue, privacy: .public) -> \(next.phase.rawValue, privacy: .public)")
            return
        }
        if let currentID = lifecycle.sessionID,
           let nextID = next.sessionID,
           currentID != nextID,
           next.phase != .preflighting {
            logger.fault("Rejected cross-session meeting state mutation")
            return
        }
        lifecycle = next
    }

    private func fail(sessionID: UUID, message: String) {
        errorMessage = message
        transition(to: .init(
            phase: .failed,
            sessionID: sessionID,
            pendingJobs: 0,
            issues: [.init(severity: .error, code: "meeting-failed", message: message)]
        ))
    }

    private func tearDownPipelines(cancel: Bool) {
        diarizers.values.forEach { $0.finish() }
        diarizers = [:]
        isPreparingDiarizer = false
        session.onAudioChunk = nil
        session.onSourceHealth = nil
    }

    @MainActor
    private static func complete(
        systemPrompt: String,
        text: String,
        engine: ZermEngine?
    ) async throws -> String {
        guard let service = engine?.enhancementService else {
            throw MeetingRecordingSession.SessionError.noSourcesSelected
        }
        return try await service.summariseMeeting(systemPrompt: systemPrompt, text: text)
    }

    @MainActor
    private static func transcribe(
        url: URL,
        engine: ZermEngine?,
        model: (any TranscriptionModel)?,
        languageCode: String
    ) async throws -> String {
        guard let engine, let model else { throw ZermEngineError.modelLoadFailed }
        return try await engine.serviceRegistry.transcribe(
            audioURL: url,
            model: model,
            languageCode: languageCode
        )
    }
}
