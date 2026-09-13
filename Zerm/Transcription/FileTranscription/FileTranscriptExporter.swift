import Foundation
import UniformTypeIdentifiers

/// Renders a file transcript as text, Markdown, subtitles or JSON. Speaker names are included in
/// every format when speakers were identified.
enum FileTranscriptExporter {
    enum Format: String, CaseIterable, Identifiable {
        case text
        case markdown
        case srt
        case vtt
        case json

        var id: Self { self }

        var fileExtension: String {
            switch self {
            case .text: "txt"
            case .markdown: "md"
            case .srt: "srt"
            case .vtt: "vtt"
            case .json: "json"
            }
        }

        var contentType: UTType {
            UTType(filenameExtension: fileExtension) ?? .plainText
        }
    }

    /// A subtitle cue. Subtitles stay short enough to read: at most `maximumCueDuration` seconds
    /// and two lines of `maximumLineLength` characters.
    struct Cue: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let lines: [String]
    }

    static let maximumCueDuration: TimeInterval = 7
    static let maximumLineLength = 42

    static func export(_ transcript: FileTranscript, as format: Format) -> String {
        switch format {
        case .text: text(transcript)
        case .markdown: markdown(transcript)
        case .srt: srt(transcript)
        case .vtt: vtt(transcript)
        case .json: json(transcript)
        }
    }

    // MARK: - Text and Markdown

    private static func text(_ transcript: FileTranscript) -> String {
        transcript.paragraphs.map { paragraph in
            let stamp = "[\(transcript.timestamp(paragraph.start))]"
            guard let speaker = paragraph.speakerIndex else { return "\(stamp) \(paragraph.text)" }
            return "\(stamp) " + BidiText.labelled(transcript.name(forSpeaker: speaker), paragraph.text)
        }
        .joined(separator: "\n\n") + "\n"
    }

    /// Headings on their own line, so each paragraph's direction follows its own text.
    private static func markdown(_ transcript: FileTranscript) -> String {
        var blocks = ["# \(transcript.sourceFileName)"]
        for paragraph in transcript.paragraphs {
            let stamp = transcript.timestamp(paragraph.start)
            if let speaker = paragraph.speakerIndex {
                blocks.append("**\(transcript.name(forSpeaker: speaker))** · \(stamp)")
            } else {
                blocks.append("**\(stamp)**")
            }
            blocks.append(paragraph.text)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Subtitles

    private static func srt(_ transcript: FileTranscript) -> String {
        cues(for: transcript).enumerated().map { number, cue in
            "\(number + 1)\n\(subtitleTime(cue.start, separator: ",")) --> \(subtitleTime(cue.end, separator: ","))\n"
                + cue.lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n") + "\n"
    }

    private static func vtt(_ transcript: FileTranscript) -> String {
        let body = cues(for: transcript).map { cue in
            "\(subtitleTime(cue.start, separator: ".")) --> \(subtitleTime(cue.end, separator: "."))\n"
                + cue.lines.map(escapeVTT).joined(separator: "\n")
        }
        return (["WEBVTT"] + body).joined(separator: "\n\n") + "\n"
    }

    /// Splits every segment into cues. Providers give no word timings, so a cue's times are
    /// interpolated across its segment by character position.
    static func cues(for transcript: FileTranscript) -> [Cue] {
        var cues: [Cue] = []
        for segment in transcript.segments {
            let words = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            let label = segment.speakerIndex.map { transcript.name(forSpeaker: $0) }
            let totalCharacters = Double(words.reduce(-1) { $0 + $1.count + 1 })
            func time(at offset: Int) -> TimeInterval {
                segment.start + (segment.end - segment.start) * min(1, Double(offset) / max(1, totalCharacters))
            }

            var cueWords: [String] = []
            var cueStart = 0
            var offset = 0

            func emit() {
                let start = time(at: cueStart)
                let end = min(time(at: offset - 1), start + maximumCueDuration)
                cues.append(Cue(start: start, end: end, lines: lines(label: label, words: cueWords)))
                cueWords = []
                cueStart = offset
            }

            for word in words {
                if !cueWords.isEmpty {
                    let wrapped = wrap(labelLength: label.map { $0.count + 2 } ?? 0, words: cueWords + [word])
                    if wrapped.count > 2 || time(at: offset + word.count) - time(at: cueStart) > maximumCueDuration {
                        emit()
                    }
                }
                cueWords.append(word)
                offset += word.count + 1
            }
            emit()
        }
        return cues
    }

    private static func lines(label: String?, words: [String]) -> [String] {
        var lines = wrap(labelLength: label.map { $0.count + 2 } ?? 0, words: words)
        if let label {
            lines[0] = BidiText.labelled(label, lines[0])
        }
        return lines
    }

    /// Greedy word wrap; the first line leaves room for the speaker label.
    private static func wrap(labelLength: Int, words: [String]) -> [String] {
        var lines: [String] = []
        var current = ""
        var limit = maximumLineLength - labelLength
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                lines.append(current)
                current = word
                limit = maximumLineLength
            }
        }
        lines.append(current)
        return lines
    }

    /// `00:00:01,000` for SRT, `00:00:01.000` for WebVTT.
    static func subtitleTime(_ seconds: TimeInterval, separator: String) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        return String(
            format: "%02d:%02d:%02d%@%03d",
            milliseconds / 3_600_000,
            milliseconds / 60_000 % 60,
            milliseconds / 1000 % 60,
            separator,
            milliseconds % 1000
        )
    }

    private static func escapeVTT(_ line: String) -> String {
        line.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - JSON

    private struct JSONDocument: Encodable {
        struct Segment: Encodable {
            let start: Double
            let end: Double
            let speaker: String?
            let text: String
        }

        let source: String
        let duration: Double
        let model: String
        let language: String
        let speakers: [String]
        let segments: [Segment]
    }

    private static func json(_ transcript: FileTranscript) -> String {
        func rounded(_ value: TimeInterval) -> Double { (value * 1000).rounded() / 1000 }
        let document = JSONDocument(
            source: transcript.sourceFileName,
            duration: rounded(transcript.duration),
            model: transcript.modelName,
            language: transcript.languageCode,
            speakers: transcript.speakers.map { transcript.name(forSpeaker: $0.index) },
            segments: transcript.segments.map { segment in
                JSONDocument.Segment(
                    start: rounded(segment.start),
                    end: rounded(segment.end),
                    speaker: segment.speakerIndex.map { transcript.name(forSpeaker: $0) },
                    text: segment.text
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
