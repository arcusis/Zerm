import Foundation

/// Rejects an enhancement that changed the writing system of the transcript.
///
/// Small instruct models will translate when a system prompt names a language, or when
/// they decide a mixed utterance has a "predominant" one. The product contract is the
/// opposite: keep every span in its original script. If the model flips the histogram,
/// the raw transcript is better than a fluent wrong-language rewrite.
enum EnhancementLanguageGuard {
    enum Script: Hashable, CaseIterable {
        case latin
        case hebrew
        case arabic
        case cyrillic
        case cjk
        case other
    }

    /// Script fidelity plus “the model started talking about itself.” A Gemma
    /// self-introduction is English-on-English, so the script check alone lets it through.
    static func isUsable(original: String, enhanced: String) -> Bool {
        if looksLikeSelfIntroduction(enhanced, original: original) { return false }
        if !accept(original: original, enhanced: enhanced) { return false }

        let sourceWords = original.split(whereSeparator: \.isWhitespace).count
        let outputWords = enhanced.split(whereSeparator: \.isWhitespace).count
        if sourceWords >= 2, outputWords > max(sourceWords * 4, sourceWords + 30) {
            return false
        }
        return true
    }

    static func looksLikeSelfIntroduction(_ text: String, original: String) -> Bool {
        let lower = text.lowercased()
        let source = original.lowercased()
        let markers = [
            "i am gemma", "i'm gemma", "i am a gemma", "an ai model", "i am an ai",
            "as an ai", "from deepmind", "open weights model", "open-weights model",
            "how can i help", "i'm here to help", "i am here to help",
            "as a large language", "ai assistant", "how can i assist",
            "i am qwen", "i'm qwen"
        ]
        if markers.contains(where: { lower.contains($0) && !source.contains($0) }) {
            return true
        }
        let identityWords = ["gemma", "deepmind", "qwen"]
        return identityWords.contains(where: { lower.contains($0) && !source.contains($0) })
    }

    static func accept(original: String, enhanced: String) -> Bool {
        let originalLetters = histogram(original)
        let enhancedLetters = histogram(enhanced)
        guard originalLetters.total > 0, enhancedLetters.total > 0 else { return true }

        for script in Script.allCases {
            let inputRatio = originalLetters.ratio(script)
            let outputRatio = enhancedLetters.ratio(script)
            // A script the speaker barely used must not appear as a real share of the output.
            if inputRatio < 0.05 && outputRatio >= 0.08 {
                return false
            }
            // A script that was actually in the input must not be erased.
            if inputRatio >= 0.15 && outputRatio < 0.05 {
                return false
            }
        }

        if let dominant = originalLetters.dominant, originalLetters.ratio(dominant) >= 0.40 {
            if enhancedLetters.ratio(dominant) < 0.20 {
                return false
            }
        }

        return true
    }

    private struct Histogram {
        var counts: [Script: Int] = [:]
        var total = 0

        var dominant: Script? {
            counts.max(by: { $0.value < $1.value })?.key
        }

        func ratio(_ script: Script) -> Double {
            guard total > 0 else { return 0 }
            return Double(counts[script, default: 0]) / Double(total)
        }
    }

    private static func histogram(_ text: String) -> Histogram {
        var histogram = Histogram()
        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar), let script = script(of: scalar) else {
                continue
            }
            histogram.counts[script, default: 0] += 1
            histogram.total += 1
        }
        return histogram
    }

    static func script(of scalar: Unicode.Scalar) -> Script? {
        guard CharacterSet.letters.contains(scalar) else { return nil }
        let value = scalar.value
        if (0x0590...0x05FF).contains(value) || (0xFB1D...0xFB4F).contains(value) {
            return .hebrew
        }
        if (0x0600...0x06FF).contains(value)
            || (0x0750...0x077F).contains(value)
            || (0x08A0...0x08FF).contains(value)
            || (0xFB50...0xFDFF).contains(value)
            || (0xFE70...0xFEFF).contains(value) {
            return .arabic
        }
        if (0x0400...0x04FF).contains(value) || (0x0500...0x052F).contains(value) {
            return .cyrillic
        }
        if (0x3040...0x30FF).contains(value)
            || (0x31F0...0x31FF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xAC00...0xD7AF).contains(value) {
            return .cjk
        }
        if (0x0041...0x005A).contains(value)
            || (0x0061...0x007A).contains(value)
            || (0x00C0...0x024F).contains(value)
            || (0x1E00...0x1EFF).contains(value)
            || (0x2C60...0x2C7F).contains(value)
            || (0xA720...0xA7FF).contains(value) {
            return .latin
        }
        return .other
    }
}
