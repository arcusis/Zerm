import Foundation

/// One timed line of a file transcript, optionally attributed to a speaker.
struct TranscriptSegment: Identifiable, Equatable, Sendable {
    /// Speakers are estimated by spreading a window's words across diarized turns, never timed
    /// per word by the provider, so they must not be presented as exact.
    enum SpeakerConfidence: Sendable {
        case estimatedFromWindow
        case unknown
    }

    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speakerIndex: Int?
    let speakerConfidence: SpeakerConfidence

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerIndex: Int? = nil,
        speakerConfidence: SpeakerConfidence = .unknown
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speakerIndex = speakerIndex
        self.speakerConfidence = speakerConfidence
    }
}

/// A stretch of speech attributed to one voice by diarization.
struct SpeakerTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    let speakerIndex: Int
    let start: TimeInterval
    let end: TimeInterval

    init(id: UUID = UUID(), speakerIndex: Int, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.speakerIndex = speakerIndex
        self.start = start
        self.end = end
    }
}
