import Foundation
import os

/// The "agentic" half of smart Read Aloud: rewrites raw on-screen text into natural, spoken
/// language using Zerm's on-device LLM (Gemma) before synthesis. Unlike `TTSTextNormalizer`
/// (instant, mechanical), this can rephrase — turning code, logs, and errors into something a
/// person would actually say out loud.
///
/// Local-first and fail-safe: if the model isn't installed or generation fails, it returns
/// `nil` so the caller falls back to the instant normalizer. Never blocks Read Aloud entirely.
@MainActor
final class TTSNaturalizer {
    private let llm: LocalLLMModelManager
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TTSNaturalizer")

    init(llm: LocalLLMModelManager = .shared) {
        self.llm = llm
    }

    var isModelInstalled: Bool { llm.isInstalled }

    /// Returns a spoken-friendly rewrite, or `nil` to signal "use the plain/normalized text".
    func naturalize(_ text: String, isCancelled: @escaping @Sendable () -> Bool = { false }) async -> String? {
        guard llm.isInstalled else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            // Completion-style framing: the text to transform is delimited and the turn ends on
            // "REWRITTEN:" so the model continues with the rewrite instead of chatting back.
            let userTurn = "TEXT:\n\(trimmed)\n\nREWRITTEN:"
            let result = try await llm.generate(system: Self.instruction, user: userTurn,
                                                maxNewTokens: maxTokens(for: trimmed),
                                                isCancelled: isCancelled)
            let cleaned = Self.cleanup(result)
            guard Self.isUsableRewrite(cleaned, source: trimmed) else {
                logger.notice("Naturalize produced a non-rewrite; falling back to cleaned text")
                return nil
            }
            return cleaned
        } catch {
            logger.error("Naturalize failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Roughly cap output near the input length so the model rewrites rather than rambles.
    private func maxTokens(for text: String) -> Int {
        let approx = text.count / 3 + 64
        return min(700, max(96, approx))
    }

    /// Imperative, no second-person identity ("You are…" makes small models introduce themselves).
    /// A one-shot example anchors the format for the small model and prevents chatty replies.
    private static let instruction = """
    Rewrite the text that appears after "TEXT:" so a text-to-speech voice can read it aloud \
    naturally — clear, warm, and conversational, the way a person would actually say it out loud. \
    This is a rewriting task only — do NOT answer the text, describe yourself, explain, or summarize.

    Rules:
    - Keep all the meaning and information. Do not add new facts.
    - Spell out letter-acronyms (API → "A P I") but keep word-acronyms (NASA, JSON).
    - Turn code, file paths, URLs, symbols, emoji, and error/log lines into plain spoken words \
    (e.g. "Error: ENOENT" → "there was a file-not-found error"). Never read an emoji or symbol by \
    its name — never say things like "white heavy check mark" or "heavy right arrow".
    - Remove markup and formatting. Expand abbreviations; read numbers and currency naturally.
    - Keep it about the same length as the original. Reply with ONLY the spoken text, nothing else.

    Example —
    TEXT:
    PR #877 merged: fixed the 42P10 dedupe index bug. Cost capture now works.
    REWRITTEN:
    Pull request 877 was merged. It fixed the four-two-P-ten dedupe index bug, so cost capture \
    now works.
    """

    /// Rejects degenerate model output (self-introductions, refusals, or wildly off-length),
    /// so Read Aloud falls back to the deterministically-cleaned text instead of speaking junk.
    private static func isUsableRewrite(_ out: String, source: String) -> Bool {
        guard !out.isEmpty else { return false }
        let lower = out.lowercased()
        let badMarkers = [
            "i am gemma", "i'm gemma", "i am a gemma", "an ai model", "i am an ai", "as an ai",
            "language model", "from deepmind", "i cannot", "i can't", "i don't have",
            "how can i help", "i'm here to help", "i am here to help", "as a large language"
        ]
        if badMarkers.contains(where: { lower.contains($0) }) { return false }

        // A rewrite should be roughly comparable in length to the source.
        let srcWords = source.split(whereSeparator: \.isWhitespace).count
        let outWords = out.split(whereSeparator: \.isWhitespace).count
        if srcWords >= 4 {
            if outWords < max(2, srcWords / 3) { return false }
            if outWords > srcWords * 3 + 25 { return false }
        }
        return true
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
