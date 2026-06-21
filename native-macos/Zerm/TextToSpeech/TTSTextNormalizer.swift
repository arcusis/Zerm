import Foundation

/// Turns raw on-screen text into something a person would actually *say*, before it reaches
/// the synthesizer. This is the instant, offline half of "smart" Read Aloud: it strips markup,
/// speaks URLs/paths/code the way a human would, spells out letter-acronyms, expands common
/// abbreviations and error codes, and collapses log/code noise — without paraphrasing.
///
/// It deliberately does NOT change meaning or summarize; the optional AI pass (`TTSNaturalizer`)
/// handles true rewriting. Keeping this purely mechanical means it's fast and predictable.
enum TTSTextNormalizer {

    /// All-caps tokens that are pronounced as words — leave them alone.
    private static let spokenAsWord: Set<String> = [
        "NASA", "NATO", "JSON", "YAML", "SQL", "GIF", "PNG", "RAM", "ROM", "SIM",
        "ASCII", "SCSI", "AJAX", "SaaS", "PaaS", "IaaS", "REST", "SOAP", "CRUD",
        "MIDI", "WYSIWYG", "FAQ", "ISO", "PDF", "URL", "OK"
    ]

    /// All-caps tokens that should be spelled out letter-by-letter.
    private static let spelledOut: Set<String> = [
        "API", "URI", "ID", "UI", "UX", "OS", "CLI", "CPU", "GPU", "SDK", "IDE",
        "HTTP", "HTTPS", "HTML", "CSS", "JS", "TS", "XML", "CSV", "UUID", "SSH",
        "DNS", "IP", "TCP", "UDP", "PR", "CI", "CD", "QA", "DB", "JWT", "CDN",
        "AWS", "GCP", "VM", "RPC", "GUI", "TTS", "STT", "LLM", "RGB", "FPS", "USB"
    ]

    /// Common error/exit codes a developer wouldn't read letter-for-letter.
    private static let errorCodes: [String: String] = [
        "ENOENT": "file not found",
        "EACCES": "permission denied",
        "EPERM": "operation not permitted",
        "ECONNREFUSED": "connection refused",
        "ECONNRESET": "connection reset",
        "ETIMEDOUT": "timed out",
        "ENOTFOUND": "not found",
        "EADDRINUSE": "address already in use",
        "EPIPE": "broken pipe",
        "NaN": "not a number"
    ]

    /// File extensions worth reading as "name dot ext" rather than running together.
    private static let fileExtensions = "swift|py|js|ts|tsx|jsx|json|yaml|yml|md|txt|sh|rb|go|rs|java|kt|cpp|hpp|c|h|html|css|scss|xml|csv|tsv|pdf|png|jpe?g|gif|svg|zip|tar|gz|log|cfg|conf|ini|toml|env|plist|lock|sql"

    static func normalize(_ raw: String) -> String {
        var text = raw

        // 1. Markdown line markers (headings, bullets, quotes, ordered lists).
        text = regexReplace(#"(?m)^\s*#{1,6}\s+"#, in: text, with: "")
        text = regexReplace(#"(?m)^\s*[-*+]\s+"#, in: text, with: "")
        text = regexReplace(#"(?m)^\s*>\s?"#, in: text, with: "")
        text = regexReplace(#"(?m)^\s*\d+[.)]\s+"#, in: text, with: "")

        // 2. Fenced code blocks: drop the fences, keep the contents.
        text = regexReplace(#"```[A-Za-z0-9_+-]*\n?"#, in: text, with: " ")

        // 3. Inline code, images, links → keep the human-readable part only.
        text = regexReplace("`([^`]+)`", in: text, with: "$1")
        text = regexReplace(#"!\[([^\]]*)\]\([^)]*\)"#, in: text, with: "$1")
        text = regexReplace(#"\[([^\]]+)\]\([^)]*\)"#, in: text, with: "$1")

        // 4. Emails, URLs, absolute paths → spoken forms (before generic dot/slash handling).
        text = matchReplace("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", in: text) { speakEmail($0) }
        text = matchReplace("(?:https?://|www\\.)[^\\s]+", in: text) { speakURL($0) }
        text = matchReplace("(?:(?<=\\s)|^)/[A-Za-z0-9._/-]+", in: text) { speakPath($0) }

        // 5. "name.ext" → "name dot ext".
        text = regexReplace("([A-Za-z0-9_-]+)\\.(\(fileExtensions))\\b", in: text, with: "$1 dot $2",
                            options: [.caseInsensitive])

        // 6. Acronyms: spell out letter-acronyms, leave word-acronyms alone.
        text = matchReplace("\\b[A-Za-z]{2,6}s?\\b", in: text) { speakAcronym($0) }

        // 7. snake_case / kebab-ish underscores and camelCase → spaced words.
        text = regexReplace("([A-Za-z0-9])_([A-Za-z0-9])", in: text, with: "$1 $2")
        text = regexReplace("([a-z0-9])([A-Z])", in: text, with: "$1 $2")

        // 8. Emphasis markers and stray symbols that shouldn't be spoken.
        text = regexReplace("[*~]{1,3}", in: text, with: "")

        // 9. Error codes → plain English.
        for (code, spoken) in errorCodes {
            text = regexReplace("\\b\(code)\\b", in: text, with: spoken)
        }

        // 10. Common abbreviations.
        text = regexReplace("\\be\\.g\\.", in: text, with: "for example", options: [.caseInsensitive])
        text = regexReplace("\\bi\\.e\\.", in: text, with: "that is", options: [.caseInsensitive])
        text = regexReplace("\\betc\\.?", in: text, with: "and so on", options: [.caseInsensitive])
        text = regexReplace("\\bvs\\.?", in: text, with: "versus", options: [.caseInsensitive])
        text = regexReplace("\\bapprox\\.", in: text, with: "approximately", options: [.caseInsensitive])

        // 11. Symbols → words.
        text = regexReplace("\\$(\\d[\\d,]*(?:\\.\\d+)?)", in: text, with: "$1 dollars")
        text = regexReplace("(\\d)\\s*%", in: text, with: "$1 percent")
        text = regexReplace("#(\\d+)", in: text, with: "number $1")
        text = regexReplace("\\s&\\s", in: text, with: " and ")

        // 12. Collapse layout whitespace into sentence flow.
        text = regexReplace("\\n{2,}", in: text, with: ". ")
        text = regexReplace("\\s*\\n\\s*", in: text, with: " ")
        text = regexReplace("[ \\t]{2,}", in: text, with: " ")
        text = regexReplace("\\s+([.,;:!?])", in: text, with: "$1")
        text = regexReplace("([.])\\1{1,}", in: text, with: ".")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Spoken-form transforms

    private static func speakEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return email }
        return parts[0] + " at " + parts[1].replacingOccurrences(of: ".", with: " dot ")
    }

    private static func speakURL(_ url: String) -> String {
        var host = url
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        host = host.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? host
        if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.replacingOccurrences(of: ".", with: " dot ")
    }

    private static func speakPath(_ path: String) -> String {
        path.split(separator: "/").joined(separator: " ")
    }

    /// Spells out letter-acronyms ("API" → "A P I"); preserves plural "s" and word-acronyms.
    private static func speakAcronym(_ token: String) -> String {
        var core = token
        var plural = false
        if core.count > 2, core.hasSuffix("s"), core.dropLast().allSatisfy(\.isUppercase) {
            core = String(core.dropLast())
            plural = true
        }
        guard core == core.uppercased(), core.allSatisfy(\.isLetter) else { return token }
        if spokenAsWord.contains(core) { return token }
        guard spelledOut.contains(core) else { return token }
        let spelled = core.map(String.init).joined(separator: " ")
        return plural ? spelled + "s" : spelled
    }

    // MARK: - Regex helpers

    private static func regexReplace(_ pattern: String, in text: String, with template: String,
                                     options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func matchReplace(_ pattern: String, in text: String,
                                     options: NSRegularExpression.Options = [],
                                     _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let nsRange = NSRange(text.startIndex..., in: text)
        var result = text
        for match in regex.matches(in: text, range: nsRange).reversed() {
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: transform(String(result[r])))
        }
        return result
    }
}
