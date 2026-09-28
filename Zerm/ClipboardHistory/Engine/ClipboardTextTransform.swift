import Foundation

enum ClipboardTextTransform: String, CaseIterable, Identifiable, Sendable {
    case lowercase
    case uppercase
    case capitalizeWords
    case sentenceCase
    case titleCase
    case camelCase
    case snakeCase
    case kebabCase
    case pascalCase
    case trim
    case stripWhitespace
    case removeEmptyLines
    case removeDuplicateLines
    case sortLines
    case reverseLines
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode
    case jsonPrettyPrint
    case jsonMinify
    case escape
    case unescape
    case countWords
    case countCharacters

    var id: String { rawValue }
    var localizedName: String { String(localized: String.LocalizationValue(displayName)) }

    private var displayName: String {
        switch self {
        case .lowercase: "Lowercase"
        case .uppercase: "Uppercase"
        case .capitalizeWords: "Capitalize Words"
        case .sentenceCase: "Sentence Case"
        case .titleCase: "Title Case"
        case .camelCase: "camelCase"
        case .snakeCase: "snake_case"
        case .kebabCase: "kebab-case"
        case .pascalCase: "PascalCase"
        case .trim: "Trim Whitespace"
        case .stripWhitespace: "Strip All Whitespace"
        case .removeEmptyLines: "Remove Empty Lines"
        case .removeDuplicateLines: "Remove Duplicate Lines"
        case .sortLines: "Sort Lines"
        case .reverseLines: "Reverse Lines"
        case .urlEncode: "URL Encode"
        case .urlDecode: "URL Decode"
        case .base64Encode: "Base64 Encode"
        case .base64Decode: "Base64 Decode"
        case .jsonPrettyPrint: "JSON Pretty Print"
        case .jsonMinify: "JSON Minify"
        case .escape: "Escape Text"
        case .unescape: "Unescape Text"
        case .countWords: "Count Words"
        case .countCharacters: "Count Characters"
        }
    }

    func apply(to text: String) -> String? {
        switch self {
        case .lowercase: text.lowercased()
        case .uppercase: text.uppercased()
        case .capitalizeWords: text.capitalized
        case .sentenceCase: Self.sentenceCase(text)
        case .titleCase: Self.words(text).map { $0.capitalized }.joined(separator: " ")
        case .camelCase: Self.casedWords(text, style: .camel, separator: "")
        case .snakeCase: Self.casedWords(text, style: .lower, separator: "_")
        case .kebabCase: Self.casedWords(text, style: .lower, separator: "-")
        case .pascalCase: Self.casedWords(text, style: .pascal, separator: "")
        case .trim: text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .stripWhitespace: text.filter { !$0.isWhitespace }
        case .removeEmptyLines: Self.lines(text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .removeDuplicateLines: Self.uniqueLines(text).joined(separator: "\n")
        case .sortLines: Self.lines(text).sorted().joined(separator: "\n")
        case .reverseLines: Self.lines(text).reversed().joined(separator: "\n")
        case .urlEncode: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        case .urlDecode: text.removingPercentEncoding
        case .base64Encode: Data(text.utf8).base64EncodedString()
        case .base64Decode: Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) }
        case .jsonPrettyPrint: Self.formatJSON(text, pretty: true)
        case .jsonMinify: Self.formatJSON(text, pretty: false)
        case .escape: Self.escape(text)
        case .unescape: Self.unescape(text)
        case .countWords: "\(text.split(whereSeparator: \.isWhitespace).count)"
        case .countCharacters: "\(text.count)"
        }
    }

    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private enum WordCase: Equatable { case camel, lower, pascal }

    private static func casedWords(_ text: String, style: WordCase, separator: String) -> String {
        words(text).enumerated().map { index, word in
            let lower = word.lowercased()
            guard style != .lower else { return lower }
            if style == .camel && index == 0 { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: separator)
    }

    private static func sentenceCase(_ text: String) -> String {
        var shouldCapitalize = true
        return String(text.lowercased().map { character in
            if shouldCapitalize && character.isLetter {
                shouldCapitalize = false
                return Character(String(character).uppercased())
            }
            if ".!?\n".contains(character) { shouldCapitalize = true }
            return character
        })
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    private static func uniqueLines(_ text: String) -> [String] {
        var seen = Set<String>()
        return lines(text).filter { seen.insert($0).inserted }
    }

    private static func formatJSON(_ text: String, pretty: Bool) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let output = try? JSONSerialization.data(
                withJSONObject: object,
                options: pretty ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed] : [.sortedKeys, .fragmentsAllowed]
              ) else { return nil }
        return String(data: output, encoding: .utf8)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
