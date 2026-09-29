import Foundation

enum ClipboardDetection {
    static let emailPattern = #"(?i)^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+$"#

    private static let colorNames: [String: String] = [
        "black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000",
        "blue": "#0000ff", "yellow": "#ffff00", "orange": "#ffa500", "purple": "#800080",
        "pink": "#ffc0cb", "gray": "#808080", "grey": "#808080", "cyan": "#00ffff",
        "magenta": "#ff00ff", "navy": "#000080", "teal": "#008080", "lime": "#00ff00"
    ]

    static func isEmail(_ text: String) -> Bool {
        let candidate = text.lowercased().hasPrefix("mailto:") ? String(text.dropFirst("mailto:".count)) : text
        return candidate.range(of: emailPattern, options: .regularExpression) != nil
    }

    static func isURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              components.scheme != nil,
              !isEmail(text),
              !text.contains(where: \.isWhitespace) else { return false }
        let scheme = components.scheme?.lowercased() ?? ""
        return components.host?.isEmpty == false || ["data", "tel", "urn"].contains(scheme)
    }

    static func colorToken(in text: String) -> String? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mapped = colorNames[candidate.lowercased()] { return mapped }
        guard candidate.range(of: #"(?i)^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$"#, options: .regularExpression) != nil else {
            guard candidate.range(of: #"(?i)^(rgb|rgba|hsl|hsla|hwb|lab|lch|oklab|oklch)\(.*\)$"#, options: .regularExpression) != nil else { return nil }
            return validColorFunction(candidate) ? candidate : nil
        }
        return candidate
    }

    private static func validColorFunction(_ value: String) -> Bool {
        guard let open = value.firstIndex(of: "("), value.last == ")" else { return false }
        let name = value[..<open].lowercased()
        let arguments = value[value.index(after: open)..<value.index(before: value.endIndex)]
        guard arguments.range(of: #"^[\w.+%\-/\s,]+$"#, options: .regularExpression) != nil else { return false }
        let parts = arguments.split(whereSeparator: { $0 == "," || $0.isWhitespace || $0 == "/" })
        let expected = ["rgb": 3, "rgba": 4, "hsl": 3, "hsla": 4, "hwb": 3, "lab": 3, "lch": 3, "oklab": 3, "oklch": 3][name]
        return expected.map { parts.count == $0 || parts.count == $0 + 1 } ?? false
    }
}

enum ClipboardCodeLanguage: String, CaseIterable, Sendable {
    case swift, javascript, typescript, python, go, rust, java, kotlin
    case c, cpp, shell, sql, json, yaml, html, css, markdown, code
}

enum ClipboardCodeDetection {
    private static let patterns: [(ClipboardCodeLanguage, String)] = [
        (.go, #"(?m)^\s*package\s+\w+|\bgo\s+func\b|\bfmt\.Print|:=\s*\w*"#),
        (.swift, #"\b(?:import\s+(?:SwiftUI|Foundation|AppKit|UIKit|Combine|SwiftData)|func\s+\w+\s*\(|struct\s+\w+\s*[:{]|let\s+\w+\s*=|var\s+\w+\s*=|guard\s+.+\s+else|@(?:State|ViewBuilder|MainActor))"#),
        (.typescript, #"\b(?:interface|type)\s+\w+\s*=|:\s*(?:string|number|boolean|void)\b|\b(?:const|let)\s+\w+\s*:\s*"#),
        (.javascript, #"\b(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=|\b(?:async\s+)?function\s+\w+\s*\(|\bexport\s+default\b|\bconsole\.log|=>\s*[{(]"#),
        (.python, #"(?m)^\s*(?:def\s+\w+\s*\(|class\s+\w+\s*[:(]|from\s+\S+\s+import\s+|if\s+__name__\s*==|print\s*\()"#),
        (.kotlin, #"\b(?:fun\s+\w+\s*\(|val\s+\w+\s*=|var\s+\w+\s*=|data\s+class\s+\w+|object\s+\w+)|\bwhen\s*\("#),
        (.java, #"\b(?:public|private|protected)\s+(?:static\s+)?(?:class|interface|enum|void|int|String)\b|\bSystem\.out\.println"#),
        (.cpp, #"#include\s*<(?:iostream|string|vector|map|memory|utility)>|\bstd::\w+|\bclass\s+\w+\s*\{"#),
        (.rust, #"\b(?:fn\s+\w+\s*\(|impl\s+\w+|trait\s+\w+|enum\s+\w+|pub\s+fn|let\s+mut)|::\w+|\buse\s+\w+::"#),
        (.c, #"#include\s*<stdio\.h>|\b(?:int|void|char)\s+main\s*\("#),
        (.shell, #"(?m)^\s*(?:if\s+\[.+|fi|then|for\s+\w+\s+in\s+.+|export\s+\w+=.+|sudo\s+.+)$"#),
        (.sql, #"(?im)^\s*(?:SELECT\s+.+\s+FROM\s+[\w.`"]+\s*;|INSERT\s+INTO\s+\w+\s*\(|CREATE\s+TABLE\s+\w+|UPDATE\s+\w+\s+SET)"#),
        (.html, #"(?is)<(?:!doctype\s+html|html|head|body|div|main|section|p|script|style)(?:\s|>)"#),
        (.css, #"(?m)(?:^|\s)[.#][\w-]+\s*\{[^}]*\b(?:color|margin|display|font|padding)\s*:"#),
        (.yaml, #"(?m)^[A-Za-z_][\w.-]*:\s*(?:\S.*)?$"#),
    ]

    static func language(in text: String) -> ClipboardCodeLanguage? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = trimmed.firstMatch(#"(?m)^```(swift|js|javascript|ts|typescript|py|python|go|rs|rust|java|kotlin|c|cpp|sh|bash|sql|json|yaml|html|css|md|markdown)?\s*$"#) {
            switch fence.lowercased() {
            case "js", "javascript": return .javascript
            case "ts", "typescript": return .typescript
            case "py", "python": return .python
            case "rs", "rust": return .rust
            case "sh", "bash": return .shell
            case "md", "markdown", "": return .markdown
            default: return ClipboardCodeLanguage(rawValue: fence.lowercased())
            }
        }
        if let data = trimmed.data(using: .utf8),
           (trimmed.first == "{" || trimmed.first == "["),
           (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return .json
        }
        if lines.contains(where: { $0.hasPrefix("#!") }) { return .shell }
        for (language, pattern) in patterns where trimmed.range(of: pattern, options: .regularExpression) != nil {
            if language == .yaml {
                let yamlKeys = trimmed.matches(of: #"(?m)^[A-Za-z_][\w.-]*:\s*[^\n]*$"#).count
                guard yamlKeys >= 2 else { continue }
            }
            return language
        }
        let codeSignalCount = [#"[{};]"#, #"(?m)^\s{2,}\S"#, #"(?m)^\s*(?:if|for|while|return|let|const|var)\b"#]
            .filter { trimmed.range(of: $0, options: .regularExpression) != nil }.count
        guard codeSignalCount >= 2 else { return nil }
        return .code
    }
}

private extension String {
    func matches(of pattern: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self))
    }

    func firstMatch(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              match.numberOfRanges > 1 else { return nil }
        if match.range(at: 1).location == NSNotFound { return "" }
        guard let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
