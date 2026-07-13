import Foundation
import SwiftData

/// Shared fetch for custom dictionary terms used by Whisper, cloud, and streaming paths.
enum VocabularyTerms {
    /// Unique vocabulary words, preserving first-seen casing, sorted A→Z.
    static func fetch(from modelContext: ModelContext, limit: Int = 100) -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let vocabularyWords = try? modelContext.fetch(descriptor) else {
            return []
        }
        var seen = Set<String>()
        var unique: [String] = []
        for word in vocabularyWords {
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(trimmed)
            }
            if unique.count >= limit { break }
        }
        return unique
    }

    /// Phrase suitable for Whisper `initial_prompt` bias (capped length).
    static func whisperPromptSuffix(from modelContext: ModelContext, maxChars: Int = 400) -> String {
        let terms = fetch(from: modelContext, limit: 80)
        guard !terms.isEmpty else { return "" }
        var suffix = " Vocabulary: " + terms.joined(separator: ", ") + "."
        if suffix.count > maxChars {
            suffix = String(suffix.prefix(maxChars - 1)) + "."
        }
        return suffix
    }

    /// Join for Deepgram keywords / similar APIs.
    static func joined(from modelContext: ModelContext, separator: String = ", ") -> String {
        fetch(from: modelContext).joined(separator: separator)
    }
}
