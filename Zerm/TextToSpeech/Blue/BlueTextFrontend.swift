import Foundation

/// Blue's character frontend. Keep transformations aligned with BlueTTS UnicodeProcessor.
enum BlueTextFrontend {
    static func sentenceChunks(_ text: String) -> [String] {
        let limit = 100
        var chunks: [String] = []
        var current = ""
        let sentencePattern = #"[^.!?]+[.!?]+\s*|[^.!?]+$"#
        let sentences = (try? NSRegularExpression(pattern: sentencePattern))?.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { Range($0.range, in: text).map { String(text[$0]) } } ?? [text]
        for sentence in sentences where !sentence.isEmpty {
            for piece in splitLongSentence(sentence, limit: limit) {
                if chunks.isEmpty {
                    chunks.append(piece)
                    continue
                }
                if current.count + piece.count > limit, !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                current += piece
                if current.count >= limit {
                    chunks.append(current)
                    current = ""
                }
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }

    private static func splitLongSentence(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(whereSeparator: \.isWhitespace) {
            let value = String(word)
            if !current.isEmpty, current.count + value.count + 1 > limit {
                pieces.append(current + " ")
                current = ""
            }
            if !current.isEmpty { current += " " }
            current += value
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.isEmpty ? [sentence] : pieces
    }

    static func normalizeHebrewNumbers(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return text }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "he_IL")
        formatter.numberStyle = .spellOut

        func words(_ digits: String) -> String? {
            guard let number = Decimal(string: digits, locale: Locale(identifier: "en_US")) else { return nil }
            return formatter.string(from: NSDecimalNumber(decimal: number))
        }

        var value = replaceMatches(#"(?<![\p{L}\d])(\d{1,2}):(\d{2})(?!\d)"#, in: text) { match in
            guard let hour = Int(match[1]), let minute = Int(match[2]), minute < 60,
                  let hourWords = words(String(hour)) else { return match[0] }
            if minute == 0 { return hourWords }
            if minute == 15 { return hourWords + " ורבע" }
            if minute == 30 { return hourWords + " וחצי" }
            if minute == 45, let nextHour = words(String((hour % 12) + 1)) { return "רבע ל" + nextHour }
            guard let minuteWords = words(String(minute)) else { return match[0] }
            return hourWords + " " + minuteWords
        }
        value = replaceMatches(#"(?<![\p{L}\d])(\d+(?:\.\d+)?)\s*%"#, in: value) { match in
            guard let numberWords = words(match[1]) else { return match[0] }
            return numberWords + " אחוז"
        }
        value = replaceMatches(#"(?<![\p{L}\d])(\d+\.\d+)(?!\d)"#, in: value) { match in
            words(match[1]) ?? match[0]
        }
        return replaceMatches(#"(?<![\p{L}\d])(\d+)(?![\p{L}\d])"#, in: value) { match in
            words(match[1]) ?? match[0]
        }
    }

    static func normalized(_ text: String, language: String) -> String {
        var value = text.decomposedStringWithCompatibilityMapping
        value = stripEmoji(value)
        let replacements: [Character: Character] = [
            "–": "-", "‑": "-", "—": "-", "_": " ",
            "“": "\"", "”": "\"", "‘": "'", "’": "'", "´": "'", "`": "'",
            "[": " ", "]": " ", "|": " ", "/": " ", "#": " ", "→": " ", "←": " "
        ]
        value = String(value.map { replacements[$0] ?? $0 })
        value = value.replacingOccurrences(of: #"[♥☆♡©\\]"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "@", with: " at ")
        value = value.replacingOccurrences(of: "e.g.,", with: "for example,")
        value = value.replacingOccurrences(of: "i.e.,", with: "that is,")
        value = value.replacingOccurrences(of: #"\s+([,.!?;:'])"#, with: "$1", options: .regularExpression)
        for pair in [("\"\"", "\""), ("''", "'"), ("``", "`")] {
            while value.contains(pair.0) { value = value.replacingOccurrences(of: pair.0, with: pair.1) }
        }
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"[.!?;:,'\"')\]}…。」』】〉》›»]$"#, options: .regularExpression) == nil {
            value += "."
        }
        return "<\(language)>\(value)</\(language)>"
    }

    static func tokenIDs(for phonemes: String, vocabulary: [String: Int], padID: Int = 0) -> [Int64] {
        let language = phonemes.range(of: #"<([a-z]+)>"#, options: .regularExpression).flatMap { range in
            phonemes[range].dropFirst().dropLast().description
        } ?? "he"
        let prepared = normalized(phonemes.replacingOccurrences(of: #"</?\w+>"#, with: "", options: .regularExpression), language: language)
        let stripped = prepared.replacingOccurrences(of: #"</?\w+>"#, with: "", options: .regularExpression)
        return stripped.unicodeScalars.map { Int64(vocabulary[String($0)] ?? padID) }
    }

    static func dominantLanguage(of text: String) -> String {
        let hebrew = text.unicodeScalars.filter { (0x0590...0x05FF).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { CharacterSet.letters.contains($0) && (0x0041...0x024F).contains($0.value) }.count
        return hebrew >= latin ? "he" : "en"
    }

    static func languageRuns(in text: String) -> [(language: String, text: String)] {
        var runs: [(language: String, text: String)] = []
        var language: String?
        var content = ""
        for scalar in text.unicodeScalars {
            let next: String?
            if (0x05D0...0x05EA).contains(scalar.value) {
                next = "he"
            } else if CharacterSet.letters.contains(scalar) {
                next = "en"
            } else {
                next = nil
            }
            if let next, let language, next != language, !content.isEmpty {
                runs.append((language, content))
                content = ""
            }
            if let next { language = next }
            content.unicodeScalars.append(scalar)
        }
        if let language, !content.isEmpty { runs.append((language, content)) }
        return runs
    }

    private static func stripEmoji(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            let value = scalar.value
            return !((0x1F000...0x1FAFF).contains(value) || (0x2600...0x27BF).contains(value) || (0x1F1E6...0x1F1FF).contains(value))
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func replaceMatches(
        _ pattern: String,
        in text: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            let values = (0..<match.numberOfRanges).map { index -> String in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
            guard let replacementRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(replacementRange, with: transform(values))
        }
        return result
    }
}
