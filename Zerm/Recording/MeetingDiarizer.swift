import Foundation
import FluidAudio
import OSLog

/// FluidAudio does not declare its runtime Sendable. Zerm gives it one owner and never accesses
/// it concurrently after model preparation: every inference/cleanup operation is confined to the
/// diarizer's serial queue. This wrapper makes that audited confinement explicit to Swift 6.
private final class MeetingDiarizerRuntime: @unchecked Sendable {
    let value: LSEENDDiarizer

    init(_ value: LSEENDDiarizer) {
        self.value = value
    }

    func initialize() async throws {
        try await value.initialize(variant: .dihard3)
    }

    func cleanup() {
        value.cleanup()
    }
}

/// Works out who is speaking, while the meeting is still running.
///
/// Uses FluidAudio's LS-EEND streaming diarizer (Apache 2.0), which is already a Zerm
/// dependency for Parakeet transcription, so this costs no new third-party code. Inference runs
/// on the Neural Engine, which is what makes it affordable to keep going for hours next to a
/// transcription model.
///
/// This is deliberately fed the **microphone track only**. The system track is by definition the
/// remote participants and the microphone is by definition the local room, so the two sides are
/// already separated by capture; diarizing the mic tells us how many people are in the room and
/// which of them is talking. Mixing both first would throw that free separation away and ask the
/// model to recover it.
final class MeetingDiarizer: @unchecked Sendable {

    enum DiarizationError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            String(localized: "Speaker identification is not available on this Mac.")
        }
    }

    /// A stretch of speech attributed to one voice.
    struct Turn: Identifiable, Equatable {
        let id: UUID
        let source: MeetingAudioSource
        let speakerIndex: Int
        let start: TimeInterval
        let end: TimeInterval
        let isFinal: Bool

        init(
            id: UUID = UUID(),
            source: MeetingAudioSource = .microphone,
            speakerIndex: Int,
            start: TimeInterval,
            end: TimeInterval,
            isFinal: Bool
        ) {
            self.id = id
            self.source = source
            self.speakerIndex = speakerIndex
            self.start = start
            self.end = end
            self.isFinal = isFinal
        }

        var label: String {
            let format = source == .systemAudio
                ? String(localized: "Remote Speaker %lld")
                : String(localized: "Speaker %lld")
            return String.localizedStringWithFormat(format, Int64(speakerIndex + 1))
        }
    }

    /// Everything upstream — the tap writer, the transcriber, the mic — is 16 kHz.
    private static let inputSampleRate: Double = 16_000

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingDiarizer")
    private let queue = DispatchQueue(label: "com.arcusis.zerm.meeting-diarizer", qos: .utility)
    private let source: MeetingAudioSource

    private var runtime: MeetingDiarizerRuntime?
    /// Guarded by `stateLock`, not by `queue`.
    ///
    /// These flags were originally read and written through `queue.sync`. That is unsafe from
    /// Swift concurrency: `prepare()` is a nonisolated async function running on the cooperative
    /// pool, and blocking a pool thread on a serial queue that is also servicing `append()` can
    /// leave the write to `isReady` unperformed while `prepare()` still returns normally — which
    /// is exactly what happened, leaving the diarizer permanently neither ready nor failed. A
    /// plain lock has none of that interaction with the concurrency runtime.
    private let stateLock = NSLock()
    private var isReady = false
    private var failed = false
    /// Monotonic: once the model has been asked to load this never goes back to false.
    ///
    /// `isReady` legitimately returns to false when `finish()` tears the session down, so it
    /// cannot answer "was a model ever loaded" — asking it that gave a confidently wrong answer
    /// after any completed meeting.
    private var everLoaded = false
    private var finishRequested = false
    private var pendingBeforeReady = Data()
    private let maximumPendingBytes = Int(inputSampleRate * 60) * MemoryLayout<Int16>.size
    private var sourceStartOffset: TimeInterval = 0
    private var hasSourceStartOffset = false

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Fires on the main actor whenever the picture of who-spoke-when changes.
    var onTurns: (([Turn]) -> Void)?

    private var finalized: [Turn] = []

    init(source: MeetingAudioSource = .microphone) {
        self.source = source
    }

    /// Whether the model loaded. False means speaker labels will never appear, which the caller
    /// needs to be able to tell apart from "loaded fine but nobody has spoken yet".
    var isAvailable: Bool { withState { isReady && !failed } }

    /// True once the model has been asked to load, successfully or not. Survives `finish()`.
    var didAttemptLoad: Bool { withState { everLoaded || failed } }

    // MARK: - Lifecycle

    /// Loads the model. Downloads it on first use, so this can take a while — the caller should
    /// not block recording on it.
    func prepare() async {
        do {
            let runtime = MeetingDiarizerRuntime(LSEENDDiarizer())
            try await runtime.initialize()
            let shouldFinish = withState { finishRequested }
            if shouldFinish {
                runtime.cleanup()
                withState { failed = true }
                return
            }
            withState {
                self.runtime = runtime
                self.everLoaded = true
                let data = self.pendingBeforeReady
                pendingBeforeReady.removeAll(keepingCapacity: false)
                if !data.isEmpty {
                    queue.async { [weak self] in self?.process(data) }
                }
                self.isReady = true
            }
            logger.notice("Diarizer ready")
        } catch {
            withState { self.failed = true }
            // Diarization is an enhancement: a meeting still records and transcribes without it.
            logger.error("Diarizer unavailable, continuing without speaker labels: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finish() {
        if !didAttemptLoad {
            withState {
                finishRequested = true
                failed = true
                pendingBeforeReady.removeAll(keepingCapacity: false)
            }
            return
        }
        queue.sync {
            if let snapshot = self.finalizeOnQueue() {
                DispatchQueue.main.async { [weak self] in self?.onTurns?(snapshot) }
            }
        }
    }

    @discardableResult
    func finishAndWait(timeout: TimeInterval = 15) async -> Bool {
        guard await waitUntilPrepared(timeout: timeout) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let remaining = max(0.1, deadline - ProcessInfo.processInfo.systemUptime)
        let gate = MeetingDiarizerFinishGate()
        let snapshot: [Turn]? = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                gate.resumeOnce(self?.finalizeOnQueue(), continuation: continuation)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining) { [weak self] in
                if let self {
                    self.withState {
                        self.finishRequested = true
                        self.failed = true
                    }
                }
                gate.resumeOnce(nil, continuation: continuation)
            }
        }
        if let snapshot {
            await MainActor.run { [weak self] in self?.onTurns?(snapshot) }
            return true
        }
        return false
    }

    func waitUntilPrepared(timeout: TimeInterval = 15) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !didAttemptLoad {
            if Task.isCancelled {
                finish()
                return false
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                finish()
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isAvailable
    }

    private func finalizeOnQueue() -> [Turn]? {
        guard withState({ isReady }), let runtime else { return nil }
        let diarizer = runtime.value
        var snapshot: [Turn]?
        do {
            _ = try diarizer.finalizeSession()
            let finalTurns = diarizer.timeline.speakers.values.flatMap(\.finalizedSegments).map {
                Self.turn(from: $0, source: source, offset: sourceStartOffset, isFinal: true)
            }
            finalized = finalTurns
            snapshot = finalTurns
        } catch {
            logger.error("Diarizer finalize failed: \(error.localizedDescription, privacy: .public)")
        }
        runtime.cleanup()
        self.runtime = nil
        withState { isReady = false }
        return snapshot
    }

    // MARK: - Ingest

    /// Takes the same 16 kHz mono Int16 chunks the transcriber gets.
    func append(_ data: Data) {
        let shouldBuffer = withState { () -> Bool in
            guard !isReady, !failed else { return false }
            pendingBeforeReady.append(data)
            if pendingBeforeReady.count > maximumPendingBytes {
                let discardedBytes = pendingBeforeReady.count - maximumPendingBytes
                // Replacing with a suffix avoids Data.removeFirst's repeated large memmove while
                // a model download is pending. Advance the retained audio's origin by exactly the
                // discarded duration so delayed model readiness cannot shift every speaker turn.
                pendingBeforeReady = Data(pendingBeforeReady.suffix(maximumPendingBytes))
                sourceStartOffset += Double(discardedBytes)
                    / Double(MemoryLayout<Int16>.size)
                    / Self.inputSampleRate
            }
            return true
        }
        if shouldBuffer { return }
        queue.async { [weak self] in
            self?.process(data)
        }
    }

    func append(_ chunk: MeetingAudioChunk) {
        guard chunk.source == source else { return }
        withState {
            if !hasSourceStartOffset {
                sourceStartOffset = chunk.timestamp
                hasSourceStartOffset = true
            }
        }
        append(chunk.data)
    }

    /// Canonical offline pass for imports and recovered sessions. It returns only finalized
    /// turns and therefore cannot lose the tail to streaming look-ahead.
    func diarizeFile(
        _ url: URL,
        startOffset: TimeInterval = 0,
        clockAnchors: [MeetingClockAnchor] = []
    ) async throws -> [Turn] {
        guard withState({ isReady && !failed }) else {
            throw DiarizationError.unavailable
        }
        let source = self.source
        let turns: [Turn] = try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: DiarizationError.unavailable)
                    return
                }
                self.diarizeFileOnQueue(
                    url,
                    source: source,
                    startOffset: startOffset,
                    clockAnchors: clockAnchors,
                    continuation: continuation
                )
            }
        }
        await MainActor.run { [weak self] in self?.onTurns?(turns) }
        return turns
    }

    private func diarizeFileOnQueue(
        _ url: URL,
        source: MeetingAudioSource,
        startOffset: TimeInterval,
        clockAnchors: [MeetingClockAnchor],
        continuation: CheckedContinuation<[Turn], Error>
    ) {
        guard let runtime else {
            continuation.resume(throwing: DiarizationError.unavailable)
            return
        }
        do {
            let timeline = try runtime.value.processComplete(
                audioFileURL: url,
                keepingEnrolledSpeakers: false,
                finalizeOnCompletion: true,
                progressCallback: nil
            )
            let result = timeline.speakers.values.flatMap(\.finalizedSegments).map { segment in
                let rawStart = TimeInterval(segment.startTime)
                let rawEnd = TimeInterval(segment.endTime)
                return Turn(
                    source: source,
                    speakerIndex: segment.speakerIndex,
                    start: clockAnchors.isEmpty
                        ? startOffset + rawStart
                        : MeetingTrackClock.meetingTime(
                            forFileTime: rawStart,
                            anchors: clockAnchors
                        ),
                    end: clockAnchors.isEmpty
                        ? startOffset + rawEnd
                        : MeetingTrackClock.meetingTime(
                            forFileTime: rawEnd,
                            anchors: clockAnchors
                        ),
                    isFinal: true
                )
            }
            continuation.resume(returning: result)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func process(_ data: Data) {
        guard withState({ isReady && !failed }), let runtime else { return }
        let diarizer = runtime.value
        let samples = Self.floatSamples(from: data)
        guard !samples.isEmpty else { return }
        do {
            try diarizer.addAudio(samples, sourceSampleRate: Self.inputSampleRate)
            if let update = try diarizer.process() {
                publish(from: diarizer, update: update)
            }
        } catch {
            logger.error("Diarization pass failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Publishing

    private func publish(from diarizer: LSEENDDiarizer, update: DiarizerTimelineUpdate?) {
        if let update {
            // Finalized turns never change again, so they accumulate. Tentative ones are the
            // model's current best guess about the last few seconds and are replaced wholesale
            // on every pass — appending them would make speakers flicker in and out.
            finalized.append(contentsOf: update.finalizedSegments.map {
                Self.turn(from: $0, source: source, offset: sourceStartOffset, isFinal: true)
            })
            let tentative = update.tentativeSegments.map {
                Self.turn(from: $0, source: source, offset: sourceStartOffset, isFinal: false)
            }
            let snapshot = finalized + tentative
            DispatchQueue.main.async { [weak self] in
                self?.onTurns?(snapshot)
            }
        } else {
            let snapshot = finalized
            DispatchQueue.main.async { [weak self] in
                self?.onTurns?(snapshot)
            }
        }
    }

    private static func turn(
        from segment: DiarizerSegment,
        source: MeetingAudioSource,
        offset: TimeInterval,
        isFinal: Bool
    ) -> Turn {
        Turn(
            source: source,
            speakerIndex: segment.speakerIndex,
            start: offset + TimeInterval(segment.startTime),
            end: offset + TimeInterval(segment.endTime),
            isFinal: isFinal
        )
    }

    private static func floatSamples(from data: Data) -> [Float] {
        data.withUnsafeBytes { raw -> [Float] in
            let ints = raw.bindMemory(to: Int16.self)
            var out = [Float]()
            out.reserveCapacity(ints.count)
            for sample in ints {
                out.append(Float(sample) / Float(Int16.max))
            }
            return out
        }
    }
}

private final class MeetingDiarizerFinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(
        _ value: [MeetingDiarizer.Turn]?,
        continuation: CheckedContinuation<[MeetingDiarizer.Turn]?, Never>
    ) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}
