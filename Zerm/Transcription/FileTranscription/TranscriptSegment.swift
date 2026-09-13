import Foundation

/// One timed line of a file transcript, optionally attributed to a speaker.
struct TranscriptSegment: Identifiable, Equatable, Codable, Sendable {
    /// How a segment's speaker was decided. Providers give no per-word timing, so a speaker is
    /// exact only when the segment's audio held one diarized speaker.
    enum SpeakerConfidence: String, Codable, Sendable {
        /// Transcribed from audio that belonged to a single diarized speaker.
        case diarizedTurn
        /// Estimated by spreading words across the diarized turns of a mixed stretch of audio.
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
