import Foundation

/// Converts coarse text windows into speaker-bounded segments when the STT provider does not
/// return word timestamps. Words are distributed proportionally across diarization turns and
/// explicitly marked estimated; they must never be presented as provider-timed truth.
enum SpeakerAttributor {
    static func split(
        _ segments: [TranscriptSegment],
        using turns: [SpeakerTurn]
    ) -> [TranscriptSegment] {
        segments.flatMap { split($0, using: turns) }.sorted { $0.start < $1.start }
    }

    private static func split(
        _ segment: TranscriptSegment,
        using allTurns: [SpeakerTurn]
    ) -> [TranscriptSegment] {
        let turns = allTurns.filter {
            min(segment.end, $0.end) > max(segment.start, $0.start)
        }
        guard !turns.isEmpty else { return [segment] }

        let speakers = Set(turns.map(\.speakerIndex))
        if speakers.count == 1, let speaker = speakers.first {
            return [.init(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speakerIndex: speaker,
                speakerConfidence: .estimatedFromWindow
            )]
        }

        var boundaries = [segment.start, segment.end]
        for turn in turns {
            boundaries.append(max(segment.start, min(segment.end, turn.start)))
            boundaries.append(max(segment.start, min(segment.end, turn.end)))
        }
        boundaries = Array(Set(boundaries)).sorted()
        let intervals = zip(boundaries, boundaries.dropFirst()).compactMap { pair -> Interval? in
            let (start, end) = pair
            guard end > start else { return nil }
            var overlapBySpeaker: [Int: TimeInterval] = [:]
            for turn in turns {
                let overlap = min(end, turn.end) - max(start, turn.start)
                if overlap > 0 { overlapBySpeaker[turn.speakerIndex, default: 0] += overlap }
            }
            return Interval(
                start: start,
                end: end,
                speaker: overlapBySpeaker.max(by: { $0.value < $1.value })?.key
            )
        }
        guard !intervals.isEmpty else { return [segment] }

        let words = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [segment] }
        let totalDuration = max(0.001, segment.end - segment.start)
        var consumed = 0
        var result: [TranscriptSegment] = []

        for (index, interval) in intervals.enumerated() {
            let upper: Int
            if index == intervals.count - 1 {
                upper = words.count
            } else {
                let elapsed = interval.end - segment.start
                upper = min(words.count, max(consumed, Int((elapsed / totalDuration * Double(words.count)).rounded())))
            }
            guard upper > consumed else { continue }
            result.append(.init(
                start: interval.start,
                end: interval.end,
                text: words[consumed..<upper].joined(separator: " "),
                speakerIndex: interval.speaker,
                speakerConfidence: interval.speaker == nil ? .unknown : .estimatedFromWindow
            ))
            consumed = upper
        }
        return result.isEmpty ? [segment] : result
    }

    private struct Interval {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: Int?
    }
}
