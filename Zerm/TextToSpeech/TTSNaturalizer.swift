import Foundation
import os

/// The "agentic" half of smart Read Aloud: rewrites raw on-screen text into natural, spoken
/// language using Zerm's on-device LLM (Gemma) before synthesis. Unlike `TTSTextNormalizer`
/// (instant, mechanical), this can rephrase — turning code, logs, and errors into something a
/// person would actually say out loud.
///
/// Local-first and explicit: AI modes require the selected local model. Failures are surfaced to
/// the user instead of silently reading a different version of the text than they requested.
@MainActor
final class TTSNaturalizer {
    private let llm: LocalLLMModelManager
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TTSNaturalizer")

    /// `nil` resolves to the shared manager. It cannot be a default argument:
    /// default arguments are evaluated in the caller's isolation, and
    /// `LocalLLMModelManager.shared` is main-actor isolated.
    init(llm: LocalLLMModelManager? = nil) {
        self.llm = llm ?? .shared
    }

    var isModelInstalled: Bool { llm.isInstalled }

    /// Transforms one complete selection before speech synthesis. The complete selection is sent
    /// as one semantic unit so Retell/Summarize/Explain do not produce unrelated sentence chunks.
    func transform(
        _ text: String,
        mode: ReadAloudMode,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> String {
        guard mode.usesLocalAI else { return text }
        guard llm.isInstalled else {
            throw TTSError.notAvailable(String(localized: "Download an on-device language model before using AI Read Aloud modes."))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTSError.notAvailable(String(localized: "No text selected")) }
        // Symbol-only input (e.g. stripped TUI borders / box-drawing from a terminal
        // selection) gives the model nothing to rewrite, and small models respond to
        // that with a self-introduction instead. Don't invoke the LLM at all.
        guard trimmed.filter(\.isLetter).count >= 2 else { return trimmed }

        let sections = Self.semanticSections(from: trimmed)
        guard sections.count > 1 else {
            return try await transformSection(trimmed, mode: mode, isCancelled: isCancelled)
        }

        var transformed: [String] = []
        transformed.reserveCapacity(sections.count)
        for section in sections {
            try Task.checkCancellation()
            transformed.append(try await transformSection(section, mode: mode, isCancelled: isCancelled))
        }

        let combined = transformed.joined(separator: "\n\n")
        // Summaries need one final synthesis pass so a long selection sounds like one account,
        // rather than a stack of unrelated per-section summaries. The intermediate summaries
        // are deliberately small enough to fit the local model's 4K context without truncation.
        if mode == .summarize, combined.count <= Self.maximumSectionCharacters {
            return try await transformSection(combined, mode: .summarize, isCancelled: isCancelled)
        }
        return combined
    }

    private func transformSection(
        _ text: String,
        mode: ReadAloudMode,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> String {

        let usesHebrew = Self.isPredominantlyHebrew(text)
        let outputLabel: String
        if usesHebrew {
            outputLabel = mode == .summarize ? "סיכום בעברית" : "גרסה מדוברת בעברית"
        } else {
            outputLabel = mode == .summarize ? "SUMMARY" : "SPOKEN VERSION"
        }
        let userTurn = "TEXT:\n\(text)\n\n\(outputLabel):"
        let result = try await llm.generate(
            system: Self.instruction(for: mode, sourceUsesHebrew: usesHebrew),
            user: userTurn,
            maxNewTokens: maxTokens(for: text, mode: mode),
            isCancelled: isCancelled
        )
        let cleaned = Self.cleanup(result)
        guard Self.isUsableTransform(cleaned, source: text, mode: mode) else {
            logger.error("Read Aloud transform produced unusable output for mode \(mode.rawValue, privacy: .public)")
            throw TTSError.notAvailable(String(localized: "The local model could not prepare a reliable spoken version. Try again or choose Read exactly."))
        }
        return cleaned
    }

    /// Keeps every source character represented without letting llama.cpp silently discard the
    /// middle of a selection when its 4K context fills. Paragraph boundaries are preferred;
    /// unusually long paragraphs fall back to sentence boundaries, then a hard character split.
    private static let maximumSectionCharacters = 5_500

    private static func semanticSections(from text: String) -> [String] {
        guard text.count > maximumSectionCharacters else { return [text] }

        let paragraphs = text.components(separatedBy: "\n\n")
        var sections: [String] = []
        var current = ""

        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { sections.append(value) }
            current = ""
        }

        for paragraph in paragraphs {
            let value = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if value.count > maximumSectionCharacters {
                flush()
                sections.append(contentsOf: sentenceSections(from: value))
            } else if current.isEmpty {
                current = value
            } else if current.count + value.count + 2 <= maximumSectionCharacters {
                current += "\n\n" + value
            } else {
                flush()
                current = value
            }
        }
        flush()
        return sections
    }

    private static func sentenceSections(from text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { value, _, _, _ in
            if let value { sentences.append(value) }
        }
        if sentences.isEmpty { return hardSections(from: text) }

        var result: [String] = []
        var current = ""
        for sentence in sentences {
            if sentence.count > maximumSectionCharacters {
                if !current.isEmpty { result.append(current); current = "" }
                result.append(contentsOf: hardSections(from: sentence))
            } else if current.count + sentence.count <= maximumSectionCharacters {
                current += sentence
            } else {
                if !current.isEmpty { result.append(current) }
                current = sentence
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func hardSections(from text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maximumSectionCharacters, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    /// Backward-compatible retell entry point used by older callers.
    func naturalize(_ text: String, isCancelled: @escaping @Sendable () -> Bool = { false }) async -> String? {
        try? await transform(text, mode: .retell, isCancelled: isCancelled)
    }

    /// Roughly cap output near the input length so the model rewrites rather than rambles.
    private func maxTokens(for text: String, mode: ReadAloudMode) -> Int {
        let approx = text.count / 3 + 64
        let ceiling = mode == .summarize ? 500 : 1_400
        return min(ceiling, max(96, approx))
    }

    /// Imperative, no second-person identity ("You are…" makes small models introduce themselves).
    /// A one-shot example anchors the format for the small model and prevents chatty replies.
    private static func instruction(for mode: ReadAloudMode, sourceUsesHebrew: Bool) -> String {
        let task: String
        switch mode {
        case .exact:
            return "Return the text unchanged."
        case .retell:
            task = "Retell all of the content naturally. Preserve its meaning and important details without adding facts."
        case .summarize:
            task = "Summarize the content for listening. Keep the important claims, decisions, names, numbers, and next actions."
        case .explain:
            task = "Explain the content clearly for a listener who has not seen it. Add only connective context supported by the text."
        case .simplify:
            task = "Rewrite the content in simpler language while preserving its meaning, names, numbers, and instructions."
        }
        let languageRequirement = sourceUsesHebrew
            ? """
            HEBREW OUTPUT IS REQUIRED. The source is Hebrew. Write the entire response in natural Hebrew script and right-to-left Hebrew word order. Do not translate it to English and do not transliterate Hebrew into Latin characters. Keep an English name or technical term only when it already appears that way in the source.
            חובה להחזיר את כל התשובה בעברית טבעית בלבד. אין לתרגם לאנגלית ואין לתעתק עברית לאותיות לטיניות.
            """
            : "Write in the same predominant language as the source and preserve intentional language switching."
        let example = sourceUsesHebrew
            ? """
            Example —
            TEXT:
            עדכון: תיקנו את התקלה החשובה, ועכשיו שמירת הנתונים עובדת.
            גרסה מדוברת בעברית:
            תיקנו את התקלה החשובה, ולכן שמירת הנתונים עובדת עכשיו.
            """
            : """
            Example —
            TEXT:
            PR #877 merged: fixed the 42P10 dedupe index bug. Cost capture now works.
            SPOKEN VERSION:
            Pull request 877 was merged. It fixed the four-two-P-ten dedupe index bug, so cost capture now works.
            """

        return """
    Transform the text that appears after "TEXT:" into spoken language. \(task)
    \(languageRequirement)
    Reply with only the words that should be spoken. Never introduce yourself or discuss the task.

    Rules:
    - Do not add unsupported facts.
    - Spell out letter-acronyms (API → "A P I") but keep word-acronyms (NASA, JSON).
    - Turn code, file paths, URLs, symbols, emoji, and error/log lines into plain spoken words \
    (e.g. "Error: ENOENT" → "there was a file-not-found error"). Never read an emoji or symbol by \
    its name — never say things like "white heavy check mark" or "heavy right arrow".
    - Remove markup and formatting. Expand abbreviations; read numbers and currency naturally.
    - If the text is a table or list, read it as natural sentences (row by row, mentioning the \
    column meaning where helpful). Never read separators or column borders.
    - Reply with ONLY the spoken text, nothing else.

    \(example)
    """
    }

    /// Rejects degenerate model output (self-introductions, refusals, or wildly off-length),
    /// so Read Aloud falls back to the deterministically-cleaned text instead of speaking junk.
    private static func isUsableTransform(_ out: String, source: String, mode: ReadAloudMode) -> Bool {
        guard !out.isEmpty else { return false }
        let lower = out.lowercased()
        let badMarkers = [
            "i am gemma", "i'm gemma", "i am a gemma", "an ai model", "i am an ai", "as an ai",
            "language model", "from deepmind", "i cannot", "i can't", "i don't have",
            "how can i help", "i'm here to help", "i am here to help", "as a large language",
            "advanced model", "open model", "ai assistant", "how can i assist", "happy to help"
        ]
        if badMarkers.contains(where: { lower.contains($0) }) { return false }

        // Identity leakage the static markers can't enumerate ("a very advanced Gemma
        // model by Google", "built by Google DeepMind", …): the rewrite may mention
        // these words only if the source text itself does.
        let srcLower = source.lowercased()
        let identityWords = ["gemma", "google", "deepmind"]
        if identityWords.contains(where: { lower.contains($0) && !srcLower.contains($0) }) {
            return false
        }

        // Small local models sometimes understand Hebrew but translate a Retell response into
        // English because the surrounding instruction is English. Never present that as a valid
        // spoken rewrite: Hebrew input must remain predominantly Hebrew.
        if isPredominantlyHebrew(source), !isPredominantlyHebrew(out) { return false }

        // A rewrite should be roughly comparable in length to the source.
        let srcWords = source.split(whereSeparator: \.isWhitespace).count
        let outWords = out.split(whereSeparator: \.isWhitespace).count
        if srcWords >= 4 {
            if mode != .summarize, outWords < max(2, srcWords / 4) { return false }
            if mode == .summarize, outWords > srcWords + 20 { return false }
            if outWords > srcWords * 3 + 50 { return false }
        } else if outWords > srcWords * 5 + 10 {
            // Tiny sources previously skipped the length check entirely, letting a
            // multi-sentence self-introduction pass as a "rewrite" of two words.
            return false
        }
        return true
    }

    private static func isPredominantlyHebrew(_ text: String) -> Bool {
        var letters = 0
        var hebrew = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if (0x0590...0x05FF).contains(scalar.value) { hebrew += 1 }
        }
        return letters > 0 && Double(hebrew) / Double(letters) >= 0.5
    }

    /// Strips any stray quoting/preamble the model might add despite instructions.
    private static func cleanup(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip chat-control tokens a small model may emit as literal text.
        text = text.replacingOccurrences(of: #"<\/?[A-Za-z0-9_]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b(end|start)_of_turn\b"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        // Drop an echoed label or a "Sure, here is..." style preamble if present.
        if let range = text.range(of: #"^(rewritten|text|here('s| is)|sure|okay)[^\n:]*:\s*"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        // Unwrap surrounding quotes.
        if text.count > 1, let first = text.first, let last = text.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
