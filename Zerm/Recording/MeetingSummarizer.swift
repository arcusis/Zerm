import Foundation
import OSLog

/// Turns a finished transcript into something worth reading: a short summary, the decisions and
/// actions, and chapter markers.
///
/// Takes a plain closure rather than reaching for a model itself, so the same code works against
/// local Ollama, a local CLI or any cloud provider Zerm is already configured with — and so the
/// prompting and parsing can be tested without a model present.
///
/// A long meeting will not fit in a modest local model's context, so the transcript is folded:
/// summarised in chunks, then the chunk summaries summarised together. That keeps a two-hour
/// meeting working on the same 8k-context local model as a ten-minute one.
struct MeetingSummarizer {

    struct Result: Equatable, Codable {
        var summary: String
        var actionItems: [String]
        var chapters: [Chapter]

        struct Chapter: Equatable, Codable {
            var start: TimeInterval
            var title: String
        }

        var isEmpty: Bool {
            summary.isEmpty && actionItems.isEmpty && chapters.isEmpty
        }
    }

    /// `(systemPrompt, userText) -> completion`.
    let complete: (String, String) async throws -> String

    /// Roughly how much transcript to hand a model at once. Deliberately conservative: the
    /// default local models Zerm ships against are small-context.
    var chunkCharacters: Int = 6_000

    private var logger: Logger {
        Logger(subsystem: "com.arcusis.zerm", category: "MeetingSummarizer")
    }

    // MARK: - Entry point

    func summarize(lines: [MeetingRecordingStore.Sidecar.Line]) async throws -> Result {
        let transcript = Self.render(lines)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Result(summary: "", actionItems: [], chapters: [])
        }

        let condensed: String
        if transcript.count > chunkCharacters {
            let chunks = Self.chunk(lines, limit: chunkCharacters)
            var partials: [String] = []
            for chunk in chunks {
                let text = Self.render(chunk)
                let partial = try await complete(Self.chunkPrompt, text)
                partials.append(partial)
            }
            condensed = partials.joined(separator: "\n\n")
        } else {
            condensed = transcript
        }

        let raw = try await complete(Self.finalPrompt, condensed)
        return Self.parse(raw, lines: lines)
    }

    // MARK: - Prompts

    private static let chunkPrompt = """
        You are condensing one section of a meeting transcript. Write a tight paragraph covering \
        what was discussed, anything decided, and anything someone agreed to do. Keep names and \
        concrete details. Do not add anything that is not in the text. Output the paragraph only.
        Write in the predominant language of the transcript; preserve intentional code-switching.
        """

    private static let finalPrompt = """
        You are summarising a meeting from its transcript. Reply in exactly this format, with \
        these three headings and nothing else:

        SUMMARY
        <a short paragraph covering what the meeting was about and what came out of it>

        ACTIONS
        - <one concrete action or decision per line, naming who owns it when the transcript says>
        - <omit this section's lines entirely if there were none>

        CHAPTERS
        - <mm:ss> <short title for a distinct topic>

        Use only what is in the transcript. Never invent an action, a name or a decision. \
        Timestamps in the transcript are the source of truth for chapter times. Keep the three \
        machine-readable headings exactly as written above, but write all content under them in \
        the predominant language of the transcript and preserve intentional code-switching.
        """

    // MARK: - Rendering and chunking

    static func render(_ lines: [MeetingRecordingStore.Sidecar.Line]) -> String {
        lines.map { line in
            let stamp = Self.clock(line.start)
            let speaker = line.speaker.map { "\($0): " } ?? ""
            return "[\(stamp)] \(speaker)\(line.text)"
        }
        .joined(separator: "\n")
    }

    /// Splits on line boundaries so a chunk never cuts a sentence in half.
    static func chunk(
        _ lines: [MeetingRecordingStore.Sidecar.Line],
        limit: Int
    ) -> [[MeetingRecordingStore.Sidecar.Line]] {
        var chunks: [[MeetingRecordingStore.Sidecar.Line]] = []
        var current: [MeetingRecordingStore.Sidecar.Line] = []
        var size = 0

        for line in lines {
            let cost = line.text.count + 16
            if size + cost > limit, !current.isEmpty {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Parsing

    /// Pulls the three sections out of the model's reply.
    ///
    /// Written to degrade rather than fail: a model that ignores the format still yields a
    /// summary — whatever it wrote — instead of an error and an empty panel.
    static func parse(_ raw: String, lines: [MeetingRecordingStore.Sidecar.Line]) -> Result {
        var summary: [String] = []
        var actions: [String] = []
        var chapters: [Result.Chapter] = []

        enum Section { case none, summary, actions, chapters }
        var section: Section = .none
        var sawHeading = false

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            switch trimmed.uppercased() {
            case "SUMMARY": section = .summary; sawHeading = true; continue
            case "ACTIONS": section = .actions; sawHeading = true; continue
            case "CHAPTERS": section = .chapters; sawHeading = true; continue
            default: break
            }
            guard !trimmed.isEmpty else { continue }

            let bulletStripped = trimmed.hasPrefix("- ")
                ? String(trimmed.dropFirst(2))
                : trimmed

            switch section {
            case .summary, .none:
                summary.append(trimmed)
            case .actions:
                actions.append(bulletStripped)
            case .chapters:
                if let chapter = Self.parseChapter(bulletStripped) {
                    chapters.append(chapter)
                }
            }
        }

        // The model ignored the format entirely — keep its text rather than throw it away.
        if !sawHeading {
            return Result(
                summary: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                actionItems: [],
                chapters: []
            )
        }

        // A chapter beyond the end of the meeting is a hallucinated timestamp.
        let end = lines.last?.end ?? .greatestFiniteMagnitude
        chapters = chapters.filter { $0.start <= end }

        return Result(
            summary: summary.joined(separator: " "),
            actionItems: actions,
            chapters: chapters
        )
    }

    private static func parseChapter(_ text: String) -> Result.Chapter? {
        // "<mm:ss> Title" or "<h:mm:ss> Title", with or without surrounding brackets.
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]<> "))
        let parts = cleaned.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }

        let components = parts[0].split(separator: ":").compactMap { Int($0) }
        guard components.count == 2 || components.count == 3 else { return nil }

        let seconds: Int
        if components.count == 2 {
            seconds = components[0] * 60 + components[1]
        } else {
            seconds = components[0] * 3600 + components[1] * 60 + components[2]
        }

        let title = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]<> -"))
        guard !title.isEmpty else { return nil }
        return Result.Chapter(start: TimeInterval(seconds), title: title)
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
