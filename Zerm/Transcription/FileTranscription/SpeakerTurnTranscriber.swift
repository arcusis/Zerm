import AVFoundation
import Foundation

/// Transcribes a diarized file one speaker span at a time (see `SpeakerTurnPlanner`), so each
/// line's speaker comes from diarization instead of being estimated from word timing.
///
/// Spans are read straight from the converted file and a span longer than a window is transcribed
/// in overlapping windows, so memory stays bounded however long the recording is. Only spans that
/// batch short turns of several speakers fall back to estimated attribution.
struct SpeakerTurnTranscriber: Sendable {
    /// After this many spans in a row fail outright, the problem is systemic (no network, a
    /// revoked key) and the job fails instead of sending hundreds more requests.
    static let maximumConsecutiveFailures = 5

    let windowed: WindowedFileTranscriber
    var configuration = SpeakerTurnPlanner.Configuration()

    func transcribeFile(
        _ url: URL,
        turns: [SpeakerTurn],
        onProgress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> WindowedFileTranscriber.Transcript {
        let input = try AVAudioFile(forReading: url)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        let spans = SpeakerTurnPlanner.plan(turns, duration: duration, configuration: configuration)
        let total = max(0.001, spans.reduce(0) { $0 + $1.audioEnd - $1.audioStart })

        var done: TimeInterval = 0
        var segments: [TranscriptSegment] = []
        var gaps: [WindowedFileTranscriber.Gap] = []
        var consecutiveFailures = 0
        var lastError: Error?

        for span in spans {
            let length = span.audioEnd - span.audioStart
            let finishedBefore = done
            let pass = try await windowed.transcribe(input, from: span.audioStart, to: span.audioEnd) { fraction in
                await onProgress?(min(1, (finishedBefore + fraction * length) / total))
            }
            done += length
            gaps += pass.transcript.gaps

            if let error = pass.lastError, pass.transcript.segments.isEmpty {
                lastError = error
                consecutiveFailures += 1
                if consecutiveFailures >= Self.maximumConsecutiveFailures { throw error }
            } else {
                consecutiveFailures = 0
            }
            segments += Self.label(pass.transcript.segments, in: span)
        }

        if segments.isEmpty, let lastError { throw lastError }
        return WindowedFileTranscriber.Transcript(segments: segments, gaps: gaps)
    }

    /// Gives a span's segments its speaker, keeping their times inside the span's speech.
    static func label(_ segments: [TranscriptSegment], in span: SpeakerTurnPlanner.Span) -> [TranscriptSegment] {
        guard let speaker = span.speakerIndex else {
            return SpeakerAttributor.split(segments, using: span.turns)
        }
        return segments.map { segment in
            let start = min(max(segment.start, span.start), span.end)
            return TranscriptSegment(
                id: segment.id,
                start: start,
                end: max(start, min(segment.end, span.end)),
                text: segment.text,
                speakerIndex: speaker,
                speakerConfidence: .diarizedTurn
            )
        }
    }
}
