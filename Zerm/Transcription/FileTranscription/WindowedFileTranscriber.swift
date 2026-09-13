import AVFoundation
import Foundation

/// Transcribes a long audio file in overlapping windows, one window at a time.
///
/// At most one staged window file and one inference call exist at a time, so an hours-long file
/// cannot create an unbounded backlog. Consecutive windows overlap so a word cut at a boundary is
/// heard whole in one of them; the duplicated overlap text is then reconciled away.
struct WindowedFileTranscriber: Sendable {

    /// A window whose transcription failed. The rest of the file is still transcribed.
    struct Gap: Equatable, Codable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let reason: String
    }

    struct Transcript: Equatable, Sendable {
        let segments: [TranscriptSegment]
        let gaps: [Gap]
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

    private let windowSeconds: Double
    private let overlapSeconds: Double
    private let transcribe: @Sendable (URL) async throws -> String

    /// `transcribe` receives one staged window file and returns its text. Pass a closure that
    /// calls `TranscriptionServiceRegistry.transcribe(audioURL:model:languageCode:)` so windows
    /// run at background priority behind Dictation.
    init(
        windowSeconds: Double = 30,
        overlapSeconds: Double = 2,
        transcribe: @escaping @Sendable (URL) async throws -> String
    ) {
        self.windowSeconds = windowSeconds
        self.overlapSeconds = min(max(0, overlapSeconds), max(0, windowSeconds / 2))
        self.transcribe = transcribe
    }

    /// The outcome of transcribing one range. `lastError` is the most recent window failure,
    /// so callers can tell a silent range from one that could not be transcribed at all.
    struct Pass {
        let transcript: Transcript
        let lastError: Error?
    }

    func transcribeFile(
        _ url: URL,
        onProgress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> Transcript {
        let input = try AVAudioFile(forReading: url)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        let pass = try await transcribe(input, from: 0, to: duration, onProgress: onProgress)
        // Every window failing is a systemic problem (no network, a missing key), not gaps.
        if pass.transcript.segments.isEmpty, let lastError = pass.lastError {
            throw lastError
        }
        return pass.transcript
    }

    /// Transcribes `start..<end` of an open file, reconciling overlapping windows within the
    /// range. Segment and gap times are positions in the file. `onProgress` receives the fraction
    /// of the range done.
    func transcribe(
        _ input: AVAudioFile,
        from start: TimeInterval,
        to end: TimeInterval,
        onProgress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> Pass {
        let rate = input.processingFormat.sampleRate
        let firstFrame = max(0, AVAudioFramePosition((start * rate).rounded()))
        let endFrame = min(input.length, AVAudioFramePosition((end * rate).rounded()))
        guard endFrame > firstFrame else {
            return Pass(transcript: Transcript(segments: [], gaps: []), lastError: nil)
        }

        let fullWindow = AVAudioFramePosition(windowSeconds * rate)
        let advance = max(1, fullWindow - AVAudioFramePosition(overlapSeconds * rate))
        var position = firstFrame
        var prior = ""
        var segments: [TranscriptSegment] = []
        var gaps: [Gap] = []
        var lastError: Error?

        while position < endFrame {
            try Task.checkCancellation()
            input.framePosition = position
            let requested = AVAudioFrameCount(min(fullWindow, endFrame - position))
            let windowStart = Double(position) / rate
            let windowEnd = Double(position + AVAudioFramePosition(requested)) / rate
            guard requested > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: input.processingFormat,
                    frameCapacity: requested
                  ) else { break }
            try input.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else { break }

            let windowURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "zerm-file-window-\(UUID().uuidString).wav"
            )
            defer { try? FileManager.default.removeItem(at: windowURL) }
            try {
                let staged = try AVAudioFile(
                    forWriting: windowURL,
                    settings: input.fileFormat.settings,
                    commonFormat: input.processingFormat.commonFormat,
                    interleaved: input.processingFormat.isInterleaved
                )
                try staged.write(from: buffer)
            }()

            do {
                let raw = try await transcribe(windowURL)
                let reconciliation = Self.reconcileResult(previous: prior, next: raw)
                prior = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reconciliation.text.isEmpty {
                    let trimmedSeconds = min(
                        overlapSeconds,
                        max(0, windowEnd - windowStart) * reconciliation.droppedFraction
                    )
                    segments.append(.init(
                        start: min(windowEnd, windowStart + trimmedSeconds),
                        end: windowEnd,
                        text: reconciliation.text
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                gaps.append(Gap(start: windowStart, end: windowEnd, reason: error.localizedDescription))
            }

            position += min(advance, AVAudioFramePosition(buffer.frameLength))
            await onProgress?(min(1, Double(position - firstFrame) / Double(endFrame - firstFrame)))
        }
        return Pass(transcript: Transcript(segments: segments, gaps: gaps), lastError: lastError)
    }

    // MARK: - Reconciliation

    static func reconcile(previous: String, next: String, maximumOverlapWords: Int = 40) -> String {
        reconcileResult(
            previous: previous,
            next: next,
            maximumOverlapWords: maximumOverlapWords
        ).text
    }

    /// Drops the prefix of `next` that repeats the suffix of `previous`, tolerating small
    /// provider word variations (roughly one edit per five words).
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
}
