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
            let result = try await llm.generate(system: Self.systemPrompt, user: trimmed,
                                                maxNewTokens: maxTokens(for: trimmed),
                                                isCancelled: isCancelled)
            let cleaned = Self.cleanup(result)
            return cleaned.isEmpty ? nil : cleaned
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

    private static let systemPrompt = """
    You prepare written text to be read aloud by a text-to-speech voice. Rewrite the user's text \
    so it sounds natural and clear when spoken by a person — not robotic.

    Rules:
    - Keep the original meaning and all important information. Do not summarize or add new facts.
    - Say acronyms the way a human would: spell out letter-acronyms (API → "A P I"), but keep \
    ones pronounced as words (NASA, JSON).
    - Convert code, file paths, URLs, symbols, and log/error lines into plain spoken language \
    (e.g. "Error: ENOENT" → "there was a file-not-found error").
    - Remove markup, emoji, and table/box-drawing characters, and anything that shouldn't be \
    spoken — never read an emoji or symbol by its name (never say "white heavy check mark").
    - Expand abbreviations and read numbers, units, and currency naturally.
    - Output ONLY the text to be spoken. No preamble, no quotes, no explanations, no markdown.
    """

    /// Strips any stray quoting/preamble the model might add despite instructions.
    private static func cleanup(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a leading "Sure, here is..." style preamble line if present.
        if let range = text.range(of: #"^(here('s| is)|sure|okay)[^\n:]*:\s*"#,
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
