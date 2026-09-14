import Foundation

/// A finished file transcript: timed segments, optionally attributed to speakers, plus the names
/// the user gave those speakers. Persisted as a JSON sidecar beside the History recording
/// (`FileTranscriptStore`) and keyed by the History row's id.
struct FileTranscript: Codable, Equatable, Sendable {
    enum SpeakerStatus: String, Codable, Sendable {
        /// Diarization ran; segments carry speaker indices.
        case identified
        /// The user turned speaker identification off.
        case notRequested
        /// Diarization failed, so the transcript was delivered without speakers.
        case failed
    }

    struct Speaker: Codable, Equatable, Sendable {
        let index: Int
        /// `nil` until the user renames the speaker; `name(forSpeaker:)` supplies the default.
        var name: String?
    }

    /// Adjacent segments of one speaker, merged for reading.
    struct Paragraph: Identifiable, Equatable, Sendable {
        let id: Int
        let start: TimeInterval
        let end: TimeInterval
        let speakerIndex: Int?
        let text: String
    }

    /// A long monologue is still broken up so timestamps stay useful for navigation.
    static let maximumParagraphDuration: TimeInterval = 90

    let transcriptionID: UUID
    let sourceFileName: String
    let duration: TimeInterval
    let modelName: String
    let languageCode: String
    let speakerStatus: SpeakerStatus
    let segments: [TranscriptSegment]
    private(set) var speakers: [Speaker]
    let gaps: [WindowedFileTranscriber.Gap]

    /// Numbers the segments' speakers in the order they first speak, so "Speaker 1" is always the
    /// first voice in the transcript.
    init(
        transcriptionID: UUID = UUID(),
        sourceFileName: String,
        duration: TimeInterval,
        modelName: String,
        languageCode: String,
        speakerStatus: SpeakerStatus,
        segments: [TranscriptSegment],
        gaps: [WindowedFileTranscriber.Gap] = []
    ) {
        var order: [Int: Int] = [:]
        let numbered = segments.map { segment -> TranscriptSegment in
            guard let original = segment.speakerIndex else { return segment }
            let index = order[original] ?? order.count
            order[original] = index
            return TranscriptSegment(
                id: segment.id,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speakerIndex: index,
                speakerConfidence: segment.speakerConfidence
            )
        }

        self.transcriptionID = transcriptionID
        self.sourceFileName = sourceFileName
        self.duration = duration
        self.modelName = modelName
        self.languageCode = languageCode
        self.speakerStatus = speakerStatus
        self.segments = numbered
        self.speakers = (0..<order.count).map { Speaker(index: $0) }
        self.gaps = gaps
    }

    var isEmpty: Bool {
        segments.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Speakers

    func name(forSpeaker index: Int) -> String {
        if let custom = speakers.first(where: { $0.index == index })?.name, !custom.isEmpty {
            return custom
        }
        return Self.defaultName(forSpeaker: index)
    }

    static func defaultName(forSpeaker index: Int) -> String {
        String(localized: "Speaker \(index + 1)")
    }

    /// An empty name restores the default.
    mutating func rename(speaker index: Int, to name: String) {
        guard let position = speakers.firstIndex(where: { $0.index == index }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers[position].name = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Reading

    var paragraphs: [Paragraph] {
        var result: [Paragraph] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = result.last,
               last.speakerIndex == segment.speakerIndex,
               segment.end - last.start <= Self.maximumParagraphDuration {
                result[result.count - 1] = Paragraph(
                    id: last.id,
                    start: last.start,
                    end: max(last.end, segment.end),
                    speakerIndex: last.speakerIndex,
                    text: last.text + " " + text
                )
            } else {
                result.append(Paragraph(
                    id: result.count,
                    start: segment.start,
                    end: segment.end,
                    speakerIndex: segment.speakerIndex,
                    text: text
                ))
            }
        }
        return result
    }

    /// The transcript as History stores and Copy places on the clipboard: one paragraph per
    /// block, prefixed with the speaker's name when speakers were identified.
    var plainText: String {
        paragraphs.map { paragraph in
            guard let speaker = paragraph.speakerIndex else { return paragraph.text }
            return BidiText.labelled(name(forSpeaker: speaker), paragraph.text)
        }
        .joined(separator: "\n\n")
    }

    /// `M:SS`, or `H:MM:SS` once the file reaches an hour.
    func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let remainder = total % 60
        if duration >= 3600 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

/// Keeps mixed Hebrew and English lines readable in plain-text formats.
///
/// A line's base direction comes from its first strong character. When a speaker label and the
/// text after it run in different directions, the text is wrapped in a Unicode first-strong
/// isolate so its punctuation stays at its own end instead of jumping across the label. Lines
/// whose parts agree get no invisible characters at all.
enum BidiText {
    static let firstStrongIsolate = "\u{2068}"
    static let popDirectionalIsolate = "\u{2069}"

    /// `true` for right-to-left, `false` for left-to-right, `nil` when the text has no letters.
    static func isRightToLeft(_ text: String) -> Bool? {
        for scalar in text.unicodeScalars {
            if isRightToLeftLetter(scalar) { return true }
            if CharacterSet.letters.contains(scalar) { return false }
        }
        return nil
    }

    /// `label: text`, isolating `text` when its direction differs from the label's.
    static func labelled(_ label: String, _ text: String) -> String {
        guard let labelDirection = isRightToLeft(label),
              let textDirection = isRightToLeft(text),
              labelDirection != textDirection else {
            return "\(label): \(text)"
        }
        return "\(label): \(firstStrongIsolate)\(text)\(popDirectionalIsolate)"
    }

    private static func isRightToLeftLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return CharacterSet.letters.contains(scalar)
        default: return false
        }
    }
}
