import Foundation

/// Plans the audio requests that transcribe a diarized file speaker by speaker.
///
/// Diarization turns are cleaned up into spans worth sending to a model: a turn too short to
/// transcribe on its own takes the speaker of a nearby longer turn, consecutive turns of one
/// speaker are joined up to a window's length (cutting at their pauses), and runs of short turns
/// from different speakers share one request instead of becoming a burst of tiny ones. Each span
/// is padded into the silence around it, never into a neighbouring span, so no word is sent twice.
enum SpeakerTurnPlanner {
    struct Configuration: Equatable, Sendable {
        /// Turns shorter than this take the speaker of a longer turn within `mergeGap`.
        var minimumTurn: TimeInterval = 1
        /// Pauses up to this long are transcribed with the speech around them rather than skipped.
        var mergeGap: TimeInterval = 2
        /// Consecutive turns shorter than this share a request even when speakers differ.
        var batchBelow: TimeInterval = 2
        /// The longest request made of batched short turns.
        var maximumBatch: TimeInterval = 15
        /// Turns of one speaker are joined up to this length. A single longer turn stays one span
        /// and is transcribed in overlapping windows.
        var maximumSpan: TimeInterval = 30
        /// Silence added before and after a span, limited to half the pause next to it.
        var padding: TimeInterval = 0.2
    }

    struct Span: Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        /// The audio to transcribe: the span plus its padding.
        let audioStart: TimeInterval
        let audioEnd: TimeInterval
        let turns: [SpeakerTurn]

        /// The span's only speaker; `nil` when short turns of several speakers were batched.
        var speakerIndex: Int? {
            let speakers = Set(turns.map(\.speakerIndex))
            return speakers.count == 1 ? speakers.first : nil
        }
    }

    static func plan(
        _ turns: [SpeakerTurn],
        duration: TimeInterval,
        configuration: Configuration = Configuration()
    ) -> [Span] {
        var groups: [[SpeakerTurn]] = []
        for turn in absorbShortTurns(normalize(turns, duration: duration), configuration: configuration) {
            if let group = groups.last, canJoin(group, turn, configuration: configuration) {
                groups[groups.count - 1].append(turn)
            } else {
                groups.append([turn])
            }
        }

        return groups.enumerated().map { index, group in
            let start = group[0].start
            let end = group[group.count - 1].end
            let pauseBefore = index > 0 ? start - groups[index - 1].last!.end : .infinity
            let pauseAfter = index < groups.count - 1 ? groups[index + 1][0].start - end : .infinity
            return Span(
                start: start,
                end: end,
                audioStart: max(0, start - min(configuration.padding, pauseBefore / 2)),
                audioEnd: min(duration, end + min(configuration.padding, pauseAfter / 2)),
                turns: group
            )
        }
    }

    /// Sorted, within the file, without overlaps or empty turns.
    static func normalize(_ turns: [SpeakerTurn], duration: TimeInterval) -> [SpeakerTurn] {
        var result: [SpeakerTurn] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            let start = max(turn.start, result.last?.end ?? 0, 0)
            let end = min(turn.end, duration)
            guard end > start else { continue }
            result.append(SpeakerTurn(speakerIndex: turn.speakerIndex, start: start, end: end))
        }
        return result
    }

    /// Gives each turn shorter than `minimumTurn` the speaker of the closest longer turn within
    /// `mergeGap`, preferring the earlier one on a tie. Isolated short turns keep their speaker.
    static func absorbShortTurns(_ turns: [SpeakerTurn], configuration: Configuration) -> [SpeakerTurn] {
        func isShort(_ turn: SpeakerTurn) -> Bool { turn.end - turn.start < configuration.minimumTurn }

        return turns.enumerated().map { index, turn in
            guard isShort(turn) else { return turn }
            let previous = turns[..<index].last { !isShort($0) }
            let next = turns[(index + 1)...].first { !isShort($0) }
            let pauseBefore = previous.map { turn.start - $0.end } ?? .infinity
            let pauseAfter = next.map { $0.start - turn.end } ?? .infinity
            let nearest = pauseBefore <= pauseAfter ? previous : next
            guard let nearest, min(pauseBefore, pauseAfter) <= configuration.mergeGap else { return turn }
            return SpeakerTurn(id: turn.id, speakerIndex: nearest.speakerIndex, start: turn.start, end: turn.end)
        }
    }

    private static func canJoin(_ group: [SpeakerTurn], _ turn: SpeakerTurn, configuration: Configuration) -> Bool {
        let start = group[0].start
        guard turn.start - group[group.count - 1].end <= configuration.mergeGap else { return false }
        if group.allSatisfy({ $0.speakerIndex == turn.speakerIndex }) {
            return turn.end - start <= configuration.maximumSpan
        }
        // Only short turns are batched, so a speaker's longer turns always keep their own label.
        func isShort(_ turn: SpeakerTurn) -> Bool { turn.end - turn.start < configuration.batchBelow }
        return isShort(turn) && group.allSatisfy(isShort) && turn.end - start <= configuration.maximumBatch
    }
}
