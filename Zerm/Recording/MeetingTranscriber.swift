import AVFoundation
import Foundation
import OSLog

/// A bounded, source-specific transcription worker.
///
/// One instance represents exactly one audio source. Local live windows are previews followed by
/// a canonical saved-track pass. For cloud models, successful live windows are durable coverage
/// and only uncovered ranges are retried after Stop, avoiding a second full upload. Both policies
/// keep realtime work bounded without making queue pressure a permanent transcript hole.
final class MeetingTranscriber: @unchecked Sendable {

    struct Segment: Identifiable, Equatable {
        enum SpeakerConfidence: String, Codable {
            case providerTimed
            case estimatedFromWindow
            case unknown
        }

        let id: UUID
        let source: MeetingAudioSource
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let assignedSpeakerIndex: Int?
        let speakerConfidence: SpeakerConfidence

        init(
            id: UUID = UUID(),
            source: MeetingAudioSource = .microphone,
            start: TimeInterval,
            end: TimeInterval,
            text: String,
            assignedSpeakerIndex: Int? = nil,
            speakerConfidence: SpeakerConfidence = .unknown
        ) {
            self.id = id
            self.source = source
            self.start = start
            self.end = end
            self.text = text
            self.assignedSpeakerIndex = assignedSpeakerIndex
            self.speakerConfidence = speakerConfidence
        }
    }

    struct Gap: Codable, Equatable {
        let source: MeetingAudioSource
        let start: TimeInterval
        let end: TimeInterval
        let reason: String
    }

    struct Reconciliation: Equatable {
        let text: String
        let droppedPrefixWords: Int
        let totalNextWords: Int

        var droppedFraction: Double {
            guard totalNextWords > 0 else { return 0 }
            return Double(droppedPrefixWords) / Double(totalNextWords)
        }
    }

    private struct Window: Sendable {
        let index: Int
        let source: MeetingAudioSource
        let start: TimeInterval
        let url: URL
    }

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingTranscriber")
    private let format = SystemAudioTrackWriter.targetFormat
    private let sampleRate: Double = 16_000
    private let source: MeetingAudioSource
    private let windowSeconds: Double
    private let overlapSeconds: Double
    private let transcribe: @Sendable (URL) async throws -> String

    private let queue = DispatchQueue(label: "com.arcusis.zerm.meeting-transcriber", qos: .utility)
    private var pending = Data()
    private var pendingStart: TimeInterval?
    private var windowIndex = 0
    private var previousText = ""

    private let windowStream: AsyncStream<Window>
    private let windowContinuation: AsyncStream<Window>.Continuation
    private var worker: Task<Void, Never>?

    /// Emitted on the main actor as each source-local preview window completes.
    var onSegment: ((Segment) -> Void)?
    var onGap: ((Gap) -> Void)?
    /// Successful provider coverage, including windows that correctly transcribe as silence.
    var onCoverage: ((ClosedRange<TimeInterval>) -> Void)?

    init(
        source: MeetingAudioSource = .microphone,
        windowSeconds: Double = 30,
        overlapSeconds: Double = 2,
        maximumQueuedWindows: Int = 4,
        transcribe: @escaping @Sendable (URL) async throws -> String
    ) {
        self.source = source
        self.windowSeconds = windowSeconds
        self.overlapSeconds = min(max(0, overlapSeconds), max(0, windowSeconds / 2))
        self.transcribe = transcribe

        var capturedContinuation: AsyncStream<Window>.Continuation!
        windowStream = AsyncStream(bufferingPolicy: .bufferingOldest(max(1, maximumQueuedWindows))) {
            capturedContinuation = $0
        }
        windowContinuation = capturedContinuation
    }

    deinit {
        windowContinuation.finish()
        worker?.cancel()
    }

    // MARK: - Live lifecycle

    func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            for await window in self.windowStream {
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: window.url)
                    continue
                }
                await self.process(window)
            }
        }
    }

    func finish() async {
        queue.sync { cutWindows(force: true) }
        windowContinuation.finish()
        await worker?.value
        worker = nil
    }

    func cancel() {
        windowContinuation.finish()
        worker?.cancel()
        worker = nil
    }

    // MARK: - Live ingest

    /// Legacy, single-source adapter used by existing tests and integrations.
    func append(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.pendingStart == nil { self.pendingStart = 0 }
            self.pending.append(data)
            self.cutWindows(force: false)
        }
    }

    func append(_ chunk: MeetingAudioChunk) {
        guard chunk.source == source else {
            reportGap(
                .init(
                    source: source,
                    start: chunk.timestamp,
                    end: chunk.end,
                    reason: String(localized: "An audio chunk was rejected by the wrong source pipeline.")
                )
            )
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let expected = (self.pendingStart ?? chunk.timestamp)
                + Double(self.pending.count / MemoryLayout<Int16>.size) / self.sampleRate
            if !self.pending.isEmpty, abs(chunk.timestamp - expected) > 0.20 {
                self.cutWindows(force: true)
                self.pendingStart = chunk.timestamp
                self.reportGap(
                    .init(
                        source: self.source,
                        start: min(expected, chunk.timestamp),
                        end: max(expected, chunk.timestamp),
                        reason: String(localized: "The capture timeline was discontinuous.")
                    )
                )
            }
            if self.pendingStart == nil { self.pendingStart = chunk.timestamp }
            self.pending.append(chunk.data)
            self.cutWindows(force: false)
        }
    }

    private func cutWindows(force: Bool) {
        while cutWindow(force: force) {}
    }

    @discardableResult
    private func cutWindow(force: Bool) -> Bool {
        let bytesPerSample = MemoryLayout<Int16>.size
        let windowBytes = Int(windowSeconds * sampleRate) * bytesPerSample
        let overlapBytes = Int(overlapSeconds * sampleRate) * bytesPerSample

        guard pending.count >= windowBytes || (force && !pending.isEmpty) else { return false }
        let takeBytes = min(pending.count, max(windowBytes, bytesPerSample))
        let start = pendingStart ?? 0
        let slice = Data(pending.prefix(takeBytes))

        guard let url = writeWindow(slice, index: windowIndex) else {
            pending.removeFirst(takeBytes)
            pendingStart = start + Double(takeBytes / bytesPerSample) / sampleRate
            reportGap(.init(
                source: source,
                start: start,
                end: pendingStart ?? start,
                reason: String(localized: "A transcription window could not be staged.")
            ))
            return true
        }

        let window = Window(index: windowIndex, source: source, start: start, url: url)
        windowIndex += 1
        switch windowContinuation.yield(window) {
        case .enqueued(_):
            break
        case .dropped(let dropped):
            let duration = Self.duration(of: dropped.url) ?? windowSeconds
            try? FileManager.default.removeItem(at: dropped.url)
            reportGap(.init(
                source: source,
                start: dropped.start,
                end: dropped.start + duration,
                reason: String(localized: "Live transcription fell behind; the completed track will be processed after Stop.")
            ))
        case .terminated:
            try? FileManager.default.removeItem(at: url)
        @unknown default:
            try? FileManager.default.removeItem(at: url)
        }

        let dropBytes = force ? takeBytes : max(bytesPerSample, takeBytes - overlapBytes)
        pending.removeFirst(min(dropBytes, pending.count))
        pendingStart = pending.isEmpty
            ? nil
            : start + Double(dropBytes / bytesPerSample) / sampleRate
        return true
    }

    private func writeWindow(_ samples: Data, index: Int) -> URL? {
        let url = Self.temporaryWindowURL(source: source, index: index)
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let frames = AVAudioFrameCount(samples.count / MemoryLayout<Int16>.size)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.int16ChannelData else { return nil }
            buffer.frameLength = frames
            samples.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(channel[0], base, samples.count)
            }
            try file.write(from: buffer)
            return url
        } catch {
            logger.error("Could not stage a transcription window: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func process(_ window: Window) async {
        defer { try? FileManager.default.removeItem(at: window.url) }
        do {
            let raw = try await transcribe(window.url)
            let reconciliation = Self.reconcileResult(previous: previousText, next: raw)
            previousText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = Self.duration(of: window.url) ?? windowSeconds
            let coveredRange = window.start...(window.start + duration)
            await MainActor.run { [weak self] in self?.onCoverage?(coveredRange) }
            guard !reconciliation.text.isEmpty else { return }
            let trimmedSeconds = min(overlapSeconds, duration * reconciliation.droppedFraction)
            let segment = Segment(
                source: window.source,
                start: window.start + trimmedSeconds,
                end: window.start + duration,
                text: reconciliation.text
            )
            await MainActor.run { [weak self] in self?.onSegment?(segment) }
        } catch {
            logger.error("Window \(window.index, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            reportGap(.init(
                source: window.source,
                start: window.start,
                end: window.start + (Self.duration(of: window.url) ?? windowSeconds),
                reason: error.localizedDescription
            ))
        }
    }

    // MARK: - Canonical post-stop pass

    /// Processes a completed track sequentially. At most one staged file and one inference call
    /// exist at a time, so an hours-long recording cannot create an unbounded backlog.
    func transcribeFile(
        _ trackURL: URL,
        source: MeetingAudioSource,
        startOffset: TimeInterval = 0,
        clockAnchors: [MeetingClockAnchor] = [],
        meetingRanges: [ClosedRange<TimeInterval>]? = nil,
        onProgress: ((Double) async -> Void)? = nil
    ) async throws -> [Segment] {
        let input = try AVAudioFile(forReading: trackURL)
        let totalFrames = input.length
        guard totalFrames > 0 else { return [] }

        let rate = input.processingFormat.sampleRate
        let fullWindow = AVAudioFramePosition(windowSeconds * rate)
        let overlap = AVAudioFramePosition(overlapSeconds * rate)
        let advance = max(1, fullWindow - overlap)
        var position: AVAudioFramePosition = 0
        var index = 0
        var prior = ""
        var result: [Segment] = []

        while position < totalFrames {
            try Task.checkCancellation()
            input.framePosition = position
            let requested = AVAudioFrameCount(min(fullWindow, totalFrames - position))
            let fileStart = Double(position) / rate
            let fileEnd = Double(position + AVAudioFramePosition(requested)) / rate
            let mappedStart = clockAnchors.isEmpty
                ? startOffset + fileStart
                : MeetingTrackClock.meetingTime(
                    forFileTime: fileStart,
                    sampleRate: rate,
                    anchors: clockAnchors
                )
            let mappedEnd = clockAnchors.isEmpty
                ? startOffset + fileEnd
                : MeetingTrackClock.meetingTime(
                    forFileTime: fileEnd,
                    sampleRate: rate,
                    anchors: clockAnchors
                )
            if let meetingRanges,
               !meetingRanges.contains(where: { $0.overlaps(mappedStart...mappedEnd) }) {
                // Selective cloud retries may jump minutes between disjoint gaps. Text from the
                // earlier gap is not overlap context for the later one and must not deduplicate it.
                prior = ""
                position += min(advance, AVAudioFramePosition(requested))
                index += 1
                await onProgress?(min(1, Double(position) / Double(totalFrames)))
                continue
            }
            guard requested > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: input.processingFormat,
                    frameCapacity: requested
                  ) else { break }
            try input.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else { break }

            let url = Self.temporaryWindowURL(source: source, index: index)
            defer { try? FileManager.default.removeItem(at: url) }
            try {
                let staged = try AVAudioFile(
                    forWriting: url,
                    settings: input.fileFormat.settings,
                    commonFormat: input.processingFormat.commonFormat,
                    interleaved: input.processingFormat.isInterleaved
                )
                try staged.write(from: buffer)
            }()

            do {
                let raw = try await transcribe(url)
                let reconciliation = Self.reconcileResult(previous: prior, next: raw)
                prior = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reconciliation.text.isEmpty {
                    let stagedDuration = max(0, fileEnd - fileStart)
                    let trimmedFileSeconds = min(
                        overlapSeconds,
                        stagedDuration * reconciliation.droppedFraction
                    )
                    let adjustedStart = clockAnchors.isEmpty
                        ? startOffset + fileStart + trimmedFileSeconds
                        : MeetingTrackClock.meetingTime(
                            forFileTime: fileStart + trimmedFileSeconds,
                            sampleRate: rate,
                            anchors: clockAnchors
                        )
                    result.append(.init(
                        source: source,
                        start: min(mappedEnd, adjustedStart),
                        end: mappedEnd,
                        text: reconciliation.text
                    ))
                }
            } catch {
                let gap = Gap(
                    source: source,
                    start: mappedStart,
                    end: mappedEnd,
                    reason: error.localizedDescription
                )
                await MainActor.run { [weak self] in self?.onGap?(gap) }
            }

            position += min(advance, AVAudioFramePosition(buffer.frameLength))
            index += 1
            await onProgress?(min(1, Double(position) / Double(totalFrames)))
        }
        return result
    }

    // MARK: - Reconciliation

    static func reconcile(previous: String, next: String, maximumOverlapWords: Int = 40) -> String {
        reconcileResult(
            previous: previous,
            next: next,
            maximumOverlapWords: maximumOverlapWords
        ).text
    }

    static func reconcileResult(
        previous: String,
        next: String,
        maximumOverlapWords: Int = 40
    ) -> Reconciliation {
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .init(text: "", droppedPrefixWords: 0, totalNextWords: 0)
        }
        let priorWords = previous.split(whereSeparator: \.isWhitespace).map(String.init)
        let nextWords = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !priorWords.isEmpty, !nextWords.isEmpty else {
            return .init(text: trimmed, droppedPrefixWords: 0, totalNextWords: nextWords.count)
        }

        func normalized(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }

        let normalizedPrior = priorWords.map(normalized)
        let normalizedNext = nextWords.map(normalized)
        let priorLimit = min(maximumOverlapWords, normalizedPrior.count)
        let nextLimit = min(maximumOverlapWords, normalizedNext.count)
        var bestNextCount = 0
        var bestSpan = 0
        var bestDistance = Int.max

        if priorLimit > 0, nextLimit > 0 {
            for priorCount in 1...priorLimit {
                for nextCount in 1...nextLimit where abs(priorCount - nextCount) <= 2 {
                    let suffix = Array(normalizedPrior.suffix(priorCount))
                    let prefix = Array(normalizedNext.prefix(nextCount))
                    let distance = tokenEditDistance(suffix, prefix)
                    let span = max(priorCount, nextCount)
                    let allowed = span <= 2 ? 0 : max(1, Int(Double(span) * 0.20))
                    guard distance <= allowed else { continue }
                    let commonSpan = min(priorCount, nextCount)
                    if commonSpan > bestSpan
                        || (commonSpan == bestSpan && distance < bestDistance)
                        || (commonSpan == bestSpan && distance == bestDistance && nextCount > bestNextCount) {
                        bestSpan = commonSpan
                        bestDistance = distance
                        bestNextCount = nextCount
                    }
                }
            }
        }
        return .init(
            text: nextWords.dropFirst(bestNextCount).joined(separator: " "),
            droppedPrefixWords: bestNextCount,
            totalNextWords: nextWords.count
        )
    }

    private static func tokenEditDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: rhs.count)
            for (rightIndex, right) in rhs.enumerated() {
                let substitution = previous[rightIndex] + (similarWord(left, right) ? 0 : 1)
                current[rightIndex + 1] = min(
                    substitution,
                    min(previous[rightIndex + 1] + 1, current[rightIndex] + 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func similarWord(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != rhs else { return true }
        guard min(lhs.count, rhs.count) >= 5, abs(lhs.count - rhs.count) <= 1 else { return false }
        return characterEditDistance(lhs, rhs, limit: 1) <= 1
    }

    private static func characterEditDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, character) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, other) in right.enumerated() {
                current[rightIndex + 1] = min(
                    previous[rightIndex] + (character == other ? 0 : 1),
                    min(previous[rightIndex + 1] + 1, current[rightIndex] + 1)
                )
            }
            if current.min() ?? 0 > limit { return limit + 1 }
            previous = current
        }
        return previous[right.count]
    }

    private func reportGap(_ gap: Gap) {
        Task { @MainActor [weak self] in self?.onGap?(gap) }
    }

    private static func temporaryWindowURL(source: MeetingAudioSource, index: Int) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "zerm-meeting-\(source.rawValue)-\(index)-\(UUID().uuidString.prefix(6)).wav"
        )
    }

    private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
