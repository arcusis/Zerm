import Foundation

/// Deterministic offline dictation commands. Runs after transcription so
/// "new line", "scratch that", and spoken punctuation work without the LLM.
enum DictationCommandProcessor {

    private static let replacements: [(pattern: String, replacement: String)] = [
        (#"(?i)\bnew\s+line\b"#, "\n"),
        (#"(?i)\bnew\s+paragraph\b"#, "\n\n"),
        (#"(?i)\bnext\s+line\b"#, "\n"),
        (#"(?i)\bcomma\b"#, ","),
        (#"(?i)\bperiod\b"#, "."),
        (#"(?i)\bfull\s+stop\b"#, "."),
        (#"(?i)\bquestion\s+mark\b"#, "?"),
        (#"(?i)\bexclamation\s+(?:mark|point)\b"#, "!"),
        (#"(?i)\bcolon\b"#, ":"),
        (#"(?i)\bsemicolon\b"#, ";"),
        (#"(?i)\bopen\s+(?:quote|quotes)\b"#, "\""),
        (#"(?i)\bclose\s+(?:quote|quotes)\b"#, "\""),
        (#"(?i)\bopen\s+paren(?:thesis)?\b"#, "("),
        (#"(?i)\bclose\s+paren(?:thesis)?\b"#, ")"),
        (#"(?i)\bdash\b"#, "—"),
        (#"(?i)\bellipsis\b"#, "…"),
    ]

    static func process(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        // "scratch that" / "delete that" — remove the previous sentence/clause.
        if let regex = try? NSRegularExpression(
            pattern: #"(?i)(?:^|\s)(?:scratch that|delete that|undo that)\b"#,
            options: []
        ) {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            if let match = matches.last {
                let cut = match.range.location
                // Drop back to previous sentence boundary when possible.
                let prefix = ns.substring(to: cut)
                if let lastBreak = prefix.lastIndex(where: { ".!?\n".contains($0) }) {
                    let keep = String(prefix[...lastBreak]).trimmingCharacters(in: .whitespaces)
                    let afterRange = NSRange(location: match.range.upperBound, length: ns.length - match.range.upperBound)
                    let after = afterRange.length > 0 ? ns.substring(with: afterRange) : ""
                    result = (keep + " " + after).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    let afterRange = NSRange(location: match.range.upperBound, length: ns.length - match.range.upperBound)
                    result = afterRange.length > 0 ? ns.substring(with: afterRange).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                }
            }
        }

        for item in replacements {
            if let regex = try? NSRegularExpression(pattern: item.pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: item.replacement)
            }
        }

        // Tidy spacing around inserted punctuation / newlines (preserve newlines).
        result = result.replacingOccurrences(of: #"[^\S\n]+([,.:;!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[^\S\n]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
