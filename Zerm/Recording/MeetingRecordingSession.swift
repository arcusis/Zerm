import AVFoundation
import Combine
import Foundation
import OSLog

/// Serial, generation-scoped capture ingress.
///
/// Core Audio callbacks never enter the main actor or touch session state. A backend delivery is
/// first placed on this private worker, where source order is preserved and the immutable session
/// timeline is applied. Deactivating the ingress drains accepted work and rejects every late
/// callback from the previous AudioUnit/tap generation.
private final class MeetingCaptureIngress: @unchecked Sendable {
    struct Failure: Equatable, Sendable {
        let source: MeetingAudioSource
        let code: String
        let message: String
        let affectsHealth: Bool
    }

    private enum Event {
        case delivery(MeetingCaptureDelivery)
        case dropped(MeetingCaptureDiscontinuity)
        case clockDiscontinuity(MeetingCaptureDiscontinuity)
        case failure(Failure)
    }

    let sessionID: UUID
    let timeline: MeetingAudioTimeline

    private let queue: DispatchQueue
    private var accepting = true
    private let deliveryHandler: (MeetingAudioChunk, Data) -> Void
    private let droppedHandler: (MeetingCaptureDiscontinuity) -> Void
    private let failureHandler: (Failure) -> Void
    private var failures: [Failure] = []

    init(
        sessionID: UUID,
        deliveryHandler: @escaping (MeetingAudioChunk, Data) -> Void,
        droppedHandler: @escaping (MeetingCaptureDiscontinuity) -> Void,
        failureHandler: @escaping (Failure) -> Void
    ) {
        self.sessionID = sessionID
        timeline = MeetingAudioTimeline(sessionID: sessionID)
        queue = DispatchQueue(label: "com.arcusis.zerm.meeting.capture.\(sessionID.uuidString)")
        self.deliveryHandler = deliveryHandler
        self.droppedHandler = droppedHandler
        self.failureHandler = failureHandler
    }

    func enqueue(_ delivery: MeetingCaptureDelivery) {
        enqueue(.delivery(delivery))
    }

    func enqueueDroppedFrames(_ discontinuity: MeetingCaptureDiscontinuity) {
        enqueue(.dropped(discontinuity))
    }

    func enqueueClockDiscontinuity(_ discontinuity: MeetingCaptureDiscontinuity) {
        enqueue(.clockDiscontinuity(discontinuity))
    }

    func enqueueFailure(_ failure: Failure) {
        enqueue(.failure(failure))
    }

    private func enqueue(_ event: Event) {
        queue.async { [weak self] in
            guard let self, self.accepting else { return }
            switch event {
            case .delivery(let delivery):
                let chunk = self.timeline.chunk(delivery)
                self.deliveryHandler(chunk, delivery.data)
            case .dropped(let discontinuity):
                self.timeline.recordDiscontinuity(
                    source: discontinuity.source,
                    droppedFrames: discontinuity.droppedFrames,
                    hostTimeNanos: discontinuity.hostTimeNanos,
                    sourceSampleTime: discontinuity.sourceSampleTime,
                    sourceSampleRate: discontinuity.sourceSampleRate
                )
                self.droppedHandler(discontinuity)
            case .clockDiscontinuity(let discontinuity):
                self.timeline.recordDiscontinuity(
                    source: discontinuity.source,
                    droppedFrames: discontinuity.droppedFrames,
                    hostTimeNanos: discontinuity.hostTimeNanos,
                    sourceSampleTime: discontinuity.sourceSampleTime,
                    sourceSampleRate: discontinuity.sourceSampleRate
                )
            case .failure(let failure):
                self.failures.append(failure)
                self.failureHandler(failure)
            }
        }
    }

    /// Returns only after all deliveries accepted before this call have been consumed.
    func deactivateAndDrain() {
        queue.sync { accepting = false }
    }

    func failureSnapshot() -> [Failure] {
        queue.sync { failures }
    }
}

/// One meeting, from the moment recording starts until the files are closed.
///
/// The microphone and the system output are captured as **separate tracks**. Mixing them at
/// capture time would be cheaper, but two tracks mean the local speaker and the remote
/// participants are already separated on disk — attribution without diarisation — and either
/// side can be re-transcribed on its own later.
///
/// Unlike dictation, this is expected to run for hours, so both tracks stream to disk as they
/// arrive and nothing accumulates in memory.
@MainActor
final class MeetingRecordingSession: ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case stopping
        case failed(String)
    }

    struct Sources: OptionSet {
        let rawValue: Int
        static let microphone = Sources(rawValue: 1 << 0)
        static let systemAudio = Sources(rawValue: 1 << 1)
        static let all: Sources = [.microphone, .systemAudio]
    }

    /// What a finished recording left on disk.
    struct Recording: Equatable {
        let id: UUID
        let folder: URL
        let startedAt: Date
        let duration: TimeInterval
        let microphoneTrack: URL?
        let systemAudioTrack: URL?
    }

    enum SessionError: LocalizedError {
        case alreadyRecording
        case noSourcesSelected
        case noMicrophoneDevice
        case systemAudioUnavailable
        case notEnoughDiskSpace(availableMB: Int)
        case storageUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return String(localized: "A recording is already running.")
            case .noSourcesSelected:
                return String(localized: "Choose at least one thing to record.")
            case .noMicrophoneDevice:
                return String(localized: "No microphone is available to record from.")
            case .systemAudioUnavailable:
                return String(localized: "Recording system audio needs macOS 14.2 or later.")
            case .notEnoughDiskSpace(let availableMB):
                return String(localized: "Only \(availableMB) MB of disk space is free. Free up some space before recording a meeting.")
            case .storageUnavailable(let detail):
                return String(localized: "The meeting could not be safely saved: \(detail)")
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var microphoneLevelDb: Float = -160
    @Published private(set) var systemAudioLevelDb: Float = -160

    /// System audio is being captured but nothing has ever come through.
    ///
    /// Almost always the missing `kTCCServiceAudioCapture` permission: an unauthorised process
    /// tap reports success on every call and delivers pure silence, so this is the only signal
    /// there is. It can also simply mean nothing is playing yet, which is why it reads as a
    /// hint for the UI rather than an error.
    @Published private(set) var systemAudioSilent = false
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var sourceHealth: [MeetingAudioSource: MeetingSourceHealth] = [:]
    @Published private(set) var issues: [MeetingRecordingIssue] = []

    /// The primary capture callback. Each delivery has a source and a position on the shared
    /// meeting clock. Consumers must keep separate pipelines per source.
    var onAudioChunk: ((MeetingAudioChunk) -> Void)?
    var onSourceHealth: ((MeetingAudioSource, MeetingSourceHealth) -> Void)?

    /// Compatibility observer for callers that only count audio. New transcription code must
    /// use `onAudioChunk`; bytes from independent sources have no valid concatenated timeline.
    var onTranscriptionChunk: ((Data) -> Void)?

    /// The microphone alone — the room you are sitting in. Kept separate from the merged feed
    /// because diarisation only makes sense per side: the system track is already known to be
    /// the remote participants, so only the local room needs voices told apart.
    var onMicrophoneChunk: ((Data) -> Void)?

    /// The system output alone — everyone joining through the call.
    var onSystemAudioChunk: ((Data) -> Void)?

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingRecordingSession")

    private let captureBackend: MeetingCaptureBackend

    private var activeSources: Sources = []
    private var waitingSources = Set<MeetingAudioSource>()
    private var recordingID: UUID?
    /// Where the live recording is being written, so the transcript can be journalled beside it.
    private(set) var folder: URL?
    private var startedAt: Date?
    private var startedUptime: TimeInterval?
    private var captureIngress: MeetingCaptureIngress?
    private var captureTarget: MeetingCaptureTarget = .allSystemAudio
    private var transcriptionSnapshot: MeetingTranscriptionSnapshot?
    private var ticker: Timer?
    private var lastDiskCheck: TimeInterval = 0
    private var lowDiskReported = false
    private var deviceSwitchObservers: [NSObjectProtocol] = []
    private var pendingMicrophoneDeviceID: AudioDeviceID?
    private var microphoneRetryAttempts = 0
    private var nextMicrophoneRetryElapsed: TimeInterval = 0
    private static let maximumMicrophoneRetryAttempts = 6

    /// Where this session writes.
    ///
    /// Injected rather than global: tests must not write into the user's real library, and a
    /// shared mutable static cannot express that safely while suites run in parallel.
    private let libraryRoot: URL?
    private let manifestWriter: (MeetingRecordingStore.Manifest, URL) throws -> Void
    private let monotonicNow: () -> TimeInterval
    private let wallClockNow: () -> Date

    init(
        libraryRoot: URL? = nil,
        captureBackend: MeetingCaptureBackend = CoreAudioMeetingCaptureBackend(),
        manifestWriter: @escaping (MeetingRecordingStore.Manifest, URL) throws -> Void = {
            try MeetingRecordingStore.writeManifest($0, into: $1)
        },
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallClockNow: @escaping () -> Date = { Date() }
    ) {
        self.libraryRoot = libraryRoot
        self.captureBackend = captureBackend
        self.manifestWriter = manifestWriter
        self.monotonicNow = monotonicNow
        self.wallClockNow = wallClockNow
        let center = NotificationCenter.default
        for name in [Notification.Name.audioDeviceSwitchRequired, Notification.Name("AudioDeviceChanged")] {
            deviceSwitchObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // `queue: .main` delivers this observer on the main thread before `post`
                // returns. Preserve that ordering so a device-change migration cannot be
                // overtaken by Stop (and so its clock discontinuity is always persisted).
                MainActor.assumeIsolated {
                    self?.handleMicrophoneDeviceChange(notification)
                }
            })
        }
    }

    deinit {
        for observer in deviceSwitchObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Control

    func start(sources: Sources = .all) throws {
        try start(
            sources: sources,
            target: .allSystemAudio,
            sessionID: UUID(),
            transcriptionSnapshot: nil
        )
    }

    func start(
        sources: Sources,
        target: MeetingCaptureTarget,
        sessionID: UUID,
        transcriptionSnapshot: MeetingTranscriptionSnapshot?
    ) throws {
        switch state {
        case .idle, .failed:
            break
        case .recording, .stopping:
            throw SessionError.alreadyRecording
        }
        guard !sources.isEmpty else { throw SessionError.noSourcesSelected }

        // Checked before anything is created: a meeting that fills the volume half way through
        // corrupts the tail of a recording nobody can go back and repeat.
        if let availableMB = Self.availableDiskMB(), availableMB < Self.minimumFreeMB {
            throw SessionError.notEnoughDiskSpace(availableMB: availableMB)
        }

        let id = sessionID
        let started = wallClockNow()
        let startUptime = monotonicNow()
        let folder = try Self.makeFolder(for: id, startedAt: started, in: libraryRoot)

        recordingID = id
        activeSessionID = id
        self.folder = folder
        startedAt = started
        startedUptime = startUptime
        captureTarget = target
        self.transcriptionSnapshot = transcriptionSnapshot
        issues = []
        sourceHealth = [:]
        waitingSources = []
        pendingMicrophoneDeviceID = nil
        microphoneRetryAttempts = 0
        nextMicrophoneRetryElapsed = 0
        if sources.contains(.microphone) { sourceHealth[.microphone] = .requested }
        if sources.contains(.systemAudio) { sourceHealth[.systemAudio] = .requested }

        guard persistManifest(status: .recording, duration: 0) else {
            try? FileManager.default.removeItem(at: folder)
            clearPreparedSession()
            throw SessionError.storageUnavailable(
                String(localized: "Zerm could not create its recovery manifest.")
            )
        }
        NotificationCenter.default.post(
            name: .meetingRecordingWillStart,
            object: self,
            userInfo: [MeetingRecordingNotificationKey.sessionID: id.uuidString]
        )

        let transcriptionHandler = onTranscriptionChunk
        let microphoneHandler = onMicrophoneChunk
        let systemHandler = onSystemAudioChunk
        let audioHandler = onAudioChunk
        let ingress = MeetingCaptureIngress(
            sessionID: id,
            deliveryHandler: { [weak self] chunk, data in
                // These pipeline callbacks intentionally stay on the capture worker. Only the
                // small health snapshot below crosses to MainActor for UI publication.
                transcriptionHandler?(data)
                switch chunk.source {
                case .microphone: microphoneHandler?(data)
                case .systemAudio: systemHandler?(data)
                case .imported: break
                }
                audioHandler?(chunk)
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeSessionID == id else { return }
                    self.updateHealth(chunk.source) { health in
                        if ![.failed, .degraded].contains(health.status) {
                            health.status = .capturing
                        }
                        health.framesCaptured += Int64(chunk.frameCount)
                        health.lastChunkTimestamp = chunk.timestamp
                    }
                }
            },
            droppedHandler: { [weak self] discontinuity in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeSessionID == id else { return }
                    self.recordDroppedFramesHealth(
                        discontinuity.droppedFrames,
                        source: discontinuity.source
                    )
                }
            },
            failureHandler: { [weak self] failure in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeSessionID == id else { return }
                    self.recordIssue(
                        source: failure.source,
                        severity: .error,
                        code: failure.code,
                        message: failure.message,
                        affectsHealth: failure.affectsHealth
                    )
                }
            }
        )
        captureIngress = ingress
        captureBackend.onChunk = { [weak ingress] delivery in ingress?.enqueue(delivery) }
        captureBackend.onFailure = { [weak ingress] source, error in
            ingress?.enqueueFailure(.init(
                source: source,
                code: "\(source.rawValue)-capture-failed",
                message: error.localizedDescription,
                affectsHealth: true
            ))
        }
        captureBackend.onInterruption = { [weak ingress] source, error in
            ingress?.enqueueFailure(.init(
                source: source,
                code: "\(source.rawValue)-capture-interrupted",
                message: error.localizedDescription,
                affectsHealth: false
            ))
        }
        captureBackend.onDroppedFrames = { [weak ingress] discontinuity in
            ingress?.enqueueDroppedFrames(discontinuity)
        }
        captureBackend.onStateChange = { [weak self] source, status, message in
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == id else { return }
                if status == .capturing {
                    self.waitingSources.remove(source)
                } else if status == .degraded {
                    self.waitingSources.insert(source)
                }
                self.updateHealth(source) { health in
                    health.status = status
                    health.message = message
                }
            }
        }

        var engaged: Sources = []

        if sources.contains(.microphone) {
            do {
                try captureBackend.startMicrophone(
                    writingTo: folder.appendingPathComponent("microphone.wav")
                )
                engaged.insert(.microphone)
            } catch {
                captureBackend.onChunk = nil
                captureBackend.onStateChange = nil
                try? FileManager.default.removeItem(at: folder)
                clearPreparedSession()
                throw error
            }
        }

        if sources.contains(.systemAudio) {
            guard #available(macOS 14.2, *) else {
                if engaged.isEmpty {
                    try? FileManager.default.removeItem(at: folder)
                    clearPreparedSession()
                    throw SessionError.systemAudioUnavailable
                }
                logger.warning("System audio capture unavailable on this macOS; continuing with the microphone alone")
                finishStart(id: id, folder: folder, startedAt: started, sources: engaged)
                return
            }

            do {
                try captureBackend.startSystemAudio(
                    writingTo: folder.appendingPathComponent("system.wav"),
                    target: target
                )
                engaged.insert(.systemAudio)
            } catch {
                captureBackend.stopSystemAudio()
                // A missing tap permission must not silently cost the user their microphone
                // track too — keep whatever is already running and surface the rest.
                if engaged.isEmpty {
                    try? FileManager.default.removeItem(at: folder)
                    clearPreparedSession()
                    throw error
                }
                recordIssue(
                    source: .systemAudio,
                    severity: .error,
                    code: "system-capture-unavailable",
                    message: error.localizedDescription
                )
                logger.error("System audio capture failed, continuing with the microphone: \(error.localizedDescription, privacy: .public)")
            }
        }

        finishStart(id: id, folder: folder, startedAt: started, sources: engaged)
    }

    private func finishStart(id: UUID, folder: URL, startedAt: Date, sources: Sources) {
        recordingID = id
        self.folder = folder
        self.startedAt = startedAt
        activeSources = sources
        if sources.contains(.microphone) { updateHealth(.microphone) { $0.status = .capturing } }
        if sources.contains(.systemAudio) { updateHealth(.systemAudio) { $0.status = .capturing } }
        elapsed = 0
        lastDiskCheck = 0
        lowDiskReported = false
        state = .recording

        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common mode so the clock and levels keep moving while a menu or resize is tracking.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker

        logger.notice("Meeting recording started (\(sources.rawValue, privacy: .public)) at \(folder.lastPathComponent, privacy: .public)")
        NotificationCenter.default.post(
            name: .meetingRecordingDidStart,
            object: self,
            userInfo: [MeetingRecordingNotificationKey.sessionID: id.uuidString]
        )
    }

    private func handleMicrophoneDeviceChange(_ notification: Notification) {
        guard state == .recording, activeSources.contains(.microphone) else { return }
        let requestedID = notification.userInfo?["newDeviceID"] as? AudioDeviceID
        let deviceID = requestedID ?? AudioDeviceManager.shared.getCurrentDevice()
        guard deviceID != 0 else {
            recordIssue(
                source: .microphone,
                severity: .warning,
                code: "microphone-device-unavailable",
                message: String(localized: "The microphone changed, but no replacement input device is available yet.")
            )
            return
        }
        pendingMicrophoneDeviceID = deviceID
        microphoneRetryAttempts = 0
        attemptMicrophoneMigration(to: deviceID)
    }

    private func attemptMicrophoneMigration(to deviceID: AudioDeviceID) {
        guard state == .recording, activeSources.contains(.microphone) else { return }
        do {
            let ingress = captureIngress
            guard try captureBackend.switchMicrophone(
                to: deviceID,
                beforeRestart: { [weak ingress] in
                    // Accepted by the source-ordered ingress before AudioOutputUnitStart. A new
                    // device callback therefore cannot overtake this same-file-frame anchor.
                    ingress?.enqueueClockDiscontinuity(.init(
                        source: .microphone,
                        droppedFrames: 0,
                        hostTimeNanos: AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()),
                        sourceSampleTime: nil,
                        sourceSampleRate: 16_000
                    ))
                }
            ) else {
                if captureBackend.microphoneCaptureIsActive {
                    pendingMicrophoneDeviceID = nil
                    microphoneRetryAttempts = 0
                }
                return
            }
            pendingMicrophoneDeviceID = nil
            microphoneRetryAttempts = 0
            recordIssue(
                source: .microphone,
                severity: .warning,
                code: "microphone-device-switched",
                message: String(localized: "The microphone changed during this meeting. Recording continued on the replacement input.")
            )
        } catch {
            let captureRecovered = captureBackend.microphoneCaptureIsActive
            var retriesExhausted = false
            if captureRecovered {
                pendingMicrophoneDeviceID = nil
                microphoneRetryAttempts = 0
            } else {
                microphoneRetryAttempts += 1
                if microphoneRetryAttempts >= Self.maximumMicrophoneRetryAttempts {
                    pendingMicrophoneDeviceID = nil
                    retriesExhausted = true
                } else {
                    let delay = min(30, pow(2, Double(microphoneRetryAttempts - 1)))
                    nextMicrophoneRetryElapsed = elapsed + delay
                }
            }
            recordIssue(
                source: .microphone,
                severity: captureRecovered ? .warning : .error,
                code: retriesExhausted
                    ? "microphone-device-retry-exhausted"
                    : "microphone-device-switch-failed",
                message: captureRecovered
                    ? String(localized: "Zerm could not move the meeting to the replacement microphone. Recording continued on the previous input.")
                    : (retriesExhausted
                        ? String(localized: "Microphone capture could not be restored after several attempts. The system-audio track continues; choose an input device to retry.")
                        : String(localized: "Microphone capture stopped while changing inputs. Zerm will retry automatically.")
                    )
            )
            logger.error("Could not switch meeting microphone: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    func retryPendingMicrophoneForTesting() {
        guard let deviceID = pendingMicrophoneDeviceID else { return }
        attemptMicrophoneMigration(to: deviceID)
    }
    #endif

    private func updateHealth(
        _ source: MeetingAudioSource,
        mutation: (inout MeetingSourceHealth) -> Void
    ) {
        var health = sourceHealth[source] ?? .requested
        mutation(&health)
        sourceHealth[source] = health
        onSourceHealth?(source, health)
    }

    private func recordDroppedFramesHealth(_ frames: Int64, source: MeetingAudioSource) {
        updateHealth(source) { health in
            health.status = .degraded
            health.droppedFrames += frames
            health.message = String(localized: "Audio processing could not keep up. Some frames were dropped.")
        }
        recordIssue(
            source: source,
            severity: .error,
            code: "capture-overrun",
            message: String(localized: "Dropped \(frames) audio frames because the bounded writer queue was full.")
        )
    }

    private func recordIssue(
        source: MeetingAudioSource? = nil,
        severity: MeetingRecordingIssue.Severity,
        code: String,
        message: String,
        affectsHealth: Bool = true
    ) {
        guard !issues.contains(where: { $0.source == source && $0.code == code }) else { return }
        let issue = MeetingRecordingIssue(
            source: source,
            severity: severity,
            code: code,
            message: message
        )
        issues.append(issue)
        if let source, affectsHealth {
            updateHealth(source) { health in
                health.status = severity == .error ? .failed : .degraded
                health.message = message
            }
        }
        _ = persistManifest(status: .recording, duration: elapsed)
    }

    func reportPersistenceIssue(code: String, message: String) {
        guard !issues.contains(where: { $0.code == code }) else { return }
        recordIssue(severity: .error, code: code, message: message)
    }

    func resolveIssue(code: String) {
        issues.removeAll { $0.code == code }
    }

    @discardableResult
    private func persistManifest(
        status: MeetingRecordingStore.Manifest.Status,
        duration: TimeInterval,
        endedAt: Date? = nil
    ) -> Bool {
        guard let recordingID, let folder, let startedAt else { return false }
        let metrics = captureIngress?.timeline.metrics() ?? [:]
        let tracks = metrics.compactMap { source, metric -> MeetingRecordingStore.Manifest.Track? in
            guard source != .imported else { return nil }
            let fileName = source == .microphone ? "microphone.wav" : "system.wav"
            return .init(
                source: source,
                fileName: fileName,
                startOffset: metric.startOffset,
                duration: metric.timelineDuration,
                frames: metric.frames,
                clockAnchors: metric.anchors
            )
        }
        let requested = sourceHealth.keys.sorted { $0.rawValue < $1.rawValue }
        let manifest = MeetingRecordingStore.Manifest(
            sessionID: recordingID,
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            duration: duration,
            captureTarget: captureTarget,
            requestedSources: requested,
            tracks: tracks,
            transcriptionSnapshot: transcriptionSnapshot,
            transcriptionStatus: transcriptionSnapshot == nil ? .notRequested : .pending,
            diarizationStatus: .pending,
            sourceHealth: Dictionary(uniqueKeysWithValues: sourceHealth.map { ($0.key.rawValue, $0.value) }),
            issues: issues
        )
        do {
            try manifestWriter(manifest, folder)
            return true
        } catch {
            logger.error("Could not persist recording manifest: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func persistManifestForFinishedRecording(
        _ recording: Recording,
        status: MeetingRecordingStore.Manifest.Status
    ) {
        var manifest = MeetingRecordingStore.readManifest(in: recording.folder)
            ?? .init(
                sessionID: recording.id,
                startedAt: recording.startedAt,
                status: status,
                captureTarget: captureTarget,
                requestedSources: []
            )
        manifest.status = status
        manifest.endedAt = wallClockNow()
        manifest.duration = recording.duration
        manifest.issues = issues
        manifest.sourceHealth = Dictionary(uniqueKeysWithValues: sourceHealth.map { ($0.key.rawValue, $0.value) })
        do {
            try manifestWriter(manifest, recording.folder)
        } catch {
            logger.error("Could not persist interrupted recording manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func clearPreparedSession() {
        captureBackend.stopMicrophone()
        captureBackend.stopSystemAudio()
        captureBackend.onChunk = nil
        captureBackend.onFailure = nil
        captureBackend.onInterruption = nil
        captureBackend.onDroppedFrames = nil
        captureBackend.onStateChange = nil
        recordingID = nil
        activeSessionID = nil
        folder = nil
        startedAt = nil
        startedUptime = nil
        captureIngress?.deactivateAndDrain()
        captureIngress = nil
        activeSources = []
        waitingSources = []
        pendingMicrophoneDeviceID = nil
        microphoneRetryAttempts = 0
        sourceHealth = [:]
        issues = []
    }

    @discardableResult
    func stop() -> Recording? {
        guard state == .recording, let recordingID, let folder, let startedAt else { return nil }
        state = .stopping

        ticker?.invalidate()
        ticker = nil

        if activeSources.contains(.microphone) {
            captureBackend.stopMicrophone()
        }

        if activeSources.contains(.systemAudio) {
            captureBackend.stopSystemAudio()
        }
        captureBackend.onChunk = nil
        captureBackend.onFailure = nil
        captureBackend.onInterruption = nil
        captureBackend.onDroppedFrames = nil
        captureBackend.onStateChange = nil
        let ingress = captureIngress
        ingress?.deactivateAndDrain()

        // Failures share the source's serial ingest stream. Reconcile them synchronously after
        // draining so Stop cannot overtake a queued MainActor health update and persist a Ready
        // manifest for frames that never reached disk or for a known capture outage.
        for failure in ingress?.failureSnapshot() ?? [] {
            recordIssue(
                source: failure.source,
                severity: .error,
                code: failure.code,
                message: failure.message,
                affectsHealth: failure.affectsHealth
            )
        }

        // Capture callbacks publish UI health asynchronously, but Stop must not let a queued
        // health task erase durable overrun evidence. The source timeline is drained above and
        // is therefore the canonical count for the final manifest.
        for (source, metric) in ingress?.timeline.metrics() ?? [:] {
            let alreadyReported = sourceHealth[source]?.droppedFrames ?? 0
            let unreported = max(0, metric.droppedFrames - alreadyReported)
            if unreported > 0 {
                recordDroppedFramesHealth(unreported, source: source)
            }
        }

        if activeSources.contains(.systemAudio),
           ((ingress?.timeline.metrics()[.systemAudio]?.frames ?? 0) == 0
                || !captureBackend.systemAudioHasSignal) {
            updateHealth(.systemAudio) { health in
                health.status = .silent
                health.message = String(localized: "No usable audio was captured from the selected application. Check the target and audio-capture permission.")
            }
            issues.append(.init(
                source: .systemAudio,
                severity: .error,
                code: "system-audio-silent",
                message: String(localized: "No usable system audio was captured. The selected application may have been silent, closed, or unavailable to capture.")
            ))
        }

        let recording = Recording(
            id: recordingID,
            folder: folder,
            startedAt: startedAt,
            duration: currentElapsed(),
            microphoneTrack: activeSources.contains(.microphone)
                ? folder.appendingPathComponent("microphone.wav") : nil,
            systemAudioTrack: activeSources.contains(.systemAudio)
                ? folder.appendingPathComponent("system.wav") : nil
        )

        for source in Array(sourceHealth.keys) {
            if let status = sourceHealth[source]?.status,
               [.requested, .capturing].contains(status) {
                updateHealth(source) { $0.status = .stopped }
            }
        }
        let savedFinalManifest = persistManifest(
            status: issues.contains(where: { $0.severity == .error }) ? .partial : .processing,
            duration: recording.duration,
            endedAt: wallClockNow()
        )
        if !savedFinalManifest {
            issues.append(.init(
                severity: .error,
                code: "manifest-finalize-failed",
                message: String(localized: "The audio was retained, but Zerm could not finalize its recovery manifest. Retry processing from the library.")
            ))
        }

        self.recordingID = nil
        activeSessionID = nil
        self.folder = nil
        self.startedAt = nil
        startedUptime = nil
        activeSources = []
        waitingSources = []
        pendingMicrophoneDeviceID = nil
        microphoneRetryAttempts = 0
        microphoneLevelDb = -160
        systemAudioLevelDb = -160
        systemAudioSilent = false
        captureIngress = nil
        state = .idle

        NotificationCenter.default.post(
            name: .meetingRecordingDidStop,
            object: self,
            userInfo: [MeetingRecordingNotificationKey.sessionID: recording.id.uuidString]
        )

        logger.notice("Meeting recording stopped after \(recording.duration, privacy: .public)s")
        return recording
    }

    /// Used by the application termination hook. Capture and file handles are closed
    /// synchronously; unfinished processing remains recoverable from the manifest and journal.
    @discardableResult
    func prepareForTermination() -> Recording? {
        guard state == .recording else { return nil }
        recordIssue(
            severity: .warning,
            code: "application-terminated",
            message: String(localized: "The application closed before meeting processing finished.")
        )
        let recording = stop()
        if let recording {
            persistManifestForFinishedRecording(recording, status: .interrupted)
        }
        return recording
    }

    // MARK: - Metering

    private func tick() {
        guard state == .recording, startedUptime != nil else { return }
        elapsed = currentElapsed()
        microphoneLevelDb = activeSources.contains(.microphone) ? captureBackend.microphoneLevelDb : -160
        systemAudioLevelDb = activeSources.contains(.systemAudio) ? captureBackend.systemAudioLevelDb : -160

        if let pendingDeviceID = pendingMicrophoneDeviceID,
           !captureBackend.microphoneCaptureIsActive,
           elapsed >= nextMicrophoneRetryElapsed {
            attemptMicrophoneMigration(to: pendingDeviceID)
        }

        // Give the call a few seconds of grace before suggesting anything is wrong.
        systemAudioSilent = activeSources.contains(.systemAudio)
            && !waitingSources.contains(.systemAudio)
            && elapsed > 5
            && !captureBackend.systemAudioHasSignal
        if systemAudioSilent, sourceHealth[.systemAudio]?.status == .capturing {
            updateHealth(.systemAudio) { health in
                health.status = .silent
                health.message = String(localized: "No signal has been received from the selected application.")
            }
        } else if !systemAudioSilent, sourceHealth[.systemAudio]?.status == .silent {
            updateHealth(.systemAudio) { health in
                health.status = .capturing
                health.message = nil
            }
        }

        if activeSources.contains(.microphone), elapsed > 5 {
            let stalled = captureBackend.microphoneSecondsSinceLastDelivery.map { $0 > 5 } ?? true
            if stalled {
                recordIssue(
                    source: .microphone,
                    severity: .error,
                    code: "microphone-callback-stalled",
                    message: String(localized: "The microphone stopped delivering audio. It may have been disconnected or changed.")
                )
            }
        }
        if activeSources.contains(.systemAudio),
           !waitingSources.contains(.systemAudio),
           elapsed > 5 {
            let callbackStalled = captureBackend.systemAudioSecondsSinceLastDelivery.map { $0 > 5 } ?? true
            if callbackStalled {
                recordIssue(
                    source: .systemAudio,
                    severity: .error,
                    code: "system-callback-stalled",
                    message: String(localized: "The selected application stopped delivering audio. It may have closed, restarted, or changed process.")
                )
            } else if captureBackend.systemAudioHasSignal,
                      captureBackend.systemAudioSecondsSinceLastSignal.map({ $0 > 30 }) == true {
                recordIssue(
                    source: .systemAudio,
                    severity: .warning,
                    code: "system-signal-lost",
                    message: String(localized: "The selected application has delivered silence for more than 30 seconds.")
                )
            }
        }

        if elapsed - lastDiskCheck >= 15 {
            lastDiskCheck = elapsed
            if !persistManifest(status: .recording, duration: elapsed) {
                reportPersistenceIssue(
                    code: "manifest-checkpoint-failed",
                    message: String(localized: "Zerm could not update meeting recovery metadata. Audio capture continues.")
                )
            }
            if !lowDiskReported,
               let availableMB = Self.availableDiskMB(),
               availableMB < 256 {
                lowDiskReported = true
                recordIssue(
                    severity: .error,
                    code: "disk-space-critical",
                    message: String(localized: "Only \(availableMB) MB of disk space remains. Stop the recording soon to protect it.")
                )
            }
        }
    }

    private func currentElapsed() -> TimeInterval {
        guard let startedUptime else { return max(0, elapsed) }
        return max(0, monotonicNow() - startedUptime)
    }

    // MARK: - Storage

    /// Recordings live outside the transcript store on purpose: they are large, they are the
    /// user's raw material, and transcript retention must never delete them behind their back.
    /// Roughly four hours of two-track 16 kHz mono, plus headroom for the models.
    private static let minimumFreeMB = 1_024

    static func availableDiskMB() -> Int? {
        guard let root = try? recordingsRoot(),
              let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(available / 1_048_576)
    }

    static func recordingsRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = base.appendingPathComponent("Zerm/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// An imported recording gets a folder of the same shape as a recorded one, so nothing
    /// downstream has to know the difference.
    static func makeImportFolder(for id: UUID, startedAt: Date, in root: URL? = nil) throws -> URL {
        try makeFolder(for: id, startedAt: startedAt, in: root)
    }

    private static func makeFolder(for id: UUID, startedAt: Date, in root: URL?) throws -> URL {
        let stamp = startedAt.formatted(
            Date.FormatStyle()
                .year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                .locale(Locale(identifier: "en_US_POSIX"))
        )
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: ", ", with: " ")
        .replacingOccurrences(of: " ", with: "_")

        let base = try root ?? recordingsRoot()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = base
            .appendingPathComponent("\(stamp)_\(id.uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
