import Foundation
import Testing
@testable import Zerm

/// Keeps the Dashboard and History translatable (#319).
///
/// Pragmatic by design: the sources are read as text rather than type-checked, so these catch
/// the regressions that actually happened — a `String` handed to `Text`, a new literal with no
/// Hebrew entry — not every conceivable one.
struct LocalizationCoverageTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let scannedFolders = ["Zerm/Views/Metrics", "Zerm/Views/History"]

    /// Shared views that only appear inside History.
    private static let scannedFiles = [
        "Zerm/Views/Common/CopyIconButton.swift",
        "Zerm/Views/Common/SaveIconButton.swift",
        "Zerm/Views/Common/TranscriptionInfoPanel.swift"
    ]

    // MARK: - Tests

    @Test func textIsNeverGivenAPlainStringVariable() throws {
        let files = try Self.sources()
        #expect(files.count > 10)

        let localizedNames = Self.localizedDeclarations(in: files.map(\.text).joined(separator: "\n"))
        let violations = files.flatMap { file in
            Self.unlocalizedTextCalls(in: file.text, localizedNames: localizedNames).map { "\(file.name): \($0)" }
        }

        #expect(
            violations.isEmpty,
            "Pass a literal or a LocalizedStringKey to Text, or use Text(verbatim:) for user data: \(violations)"
        )
    }

    @Test func everyKeyHasAHebrewTranslation() throws {
        let translated = try Self.hebrewCatalogKeys()
        var missing: [String] = []
        var checked = 0

        for file in try Self.sources() {
            for key in Self.localizationKeys(in: file.text) {
                checked += 1
                switch key {
                case .exact(let text):
                    if !translated.contains(text) { missing.append("\(file.name): \(text)") }
                case .pattern(let pattern):
                    let regex = try NSRegularExpression(pattern: "^\(pattern)$")
                    let found = translated.contains { key in
                        regex.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil
                    }
                    if !found { missing.append("\(file.name): /\(pattern)/") }
                }
            }
        }

        #expect(checked > 100)
        #expect(missing.isEmpty, "Add Hebrew entries to Localizable.xcstrings for: \(missing)")
    }

    @Test func dashboardRangeLabelsAreTranslated() throws {
        let translated = try Self.hebrewCatalogKeys()
        for range in UsageRange.allCases {
            #expect(translated.contains(range.title.key))
            #expect(translated.contains(range.caption.key))
        }
    }

    @Test func detectorFlagsStringVariablesOnly() {
        let source = """
        let title: LocalizedStringKey
        Text(title)
        Text(name)
        Text(item.label)
        Text(verbatim: name)
        Text("Literal")
        Text(String(format: "%d", 1))
        """

        #expect(Self.unlocalizedTextCalls(in: source, localizedNames: Self.localizedDeclarations(in: source)) == [
            "Text(name)",
            "Text(item.label)",
            "Text(String("
        ])
    }

    @Test func keyExtractionReadsLiteralsTernariesAndInterpolations() {
        let source = #"""
        Text("Plain")
        Button(flag ? "Yes" : "No") {}
        Text("history_selected_count \(items.count)")
        Text(verbatim: "Not a key")
        NotificationManager.shared.showNotification(title: "Not a key either", type: .info)
        """#

        #expect(Self.localizationKeys(in: source) == [
            .exact("Plain"),
            .exact("Yes"),
            .exact("No"),
            .pattern(NSRegularExpression.escapedPattern(for: "history_selected_count ") + Self.formatSpecifier)
        ])
    }

    // MARK: - Sources

    private static func sources() throws -> [(name: String, text: String)] {
        var urls = scannedFiles.map { repoRoot.appending(path: $0) }
        for folder in scannedFolders {
            let enumerator = FileManager.default.enumerator(at: repoRoot.appending(path: folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "swift" { urls.append(url) }
            }
        }
        return try urls.sorted { $0.path < $1.path }.map {
            ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8))
        }
    }

    private static func hebrewCatalogKeys() throws -> Set<String> {
        let data = try Data(contentsOf: repoRoot.appending(path: "Zerm/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
        return Set(strings.compactMap { key, entry in
            (entry["localizations"] as? [String: Any])?["he"] == nil ? nil : key
        })
    }

    // MARK: - Text(String) detection

    private static func localizedDeclarations(in text: String) -> Set<String> {
        Set(captures(#"(\w+)\s*:\s*Localized(?:StringKey|StringResource)\b"#, in: text).map { $0[1] })
    }

    private static func unlocalizedTextCalls(in text: String, localizedNames: Set<String>) -> [String] {
        captures(#"(?<![\w.])Text\(\s*(?:String\(|([A-Za-z_][\w.]*)\s*\))"#, in: text).compactMap { match in
            guard !match[1].isEmpty else { return match[0] }
            let name = match[1].split(separator: ".").last.map(String.init) ?? match[1]
            return localizedNames.contains(name) ? nil : match[0]
        }
    }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : string.substring(with: range)
            }
        }
    }

    // MARK: - Key extraction

    enum SourceKey: Equatable {
        case exact(String)
        /// A literal with interpolations, as a regex in which every value is a format specifier.
        case pattern(String)
    }

    private static let formatSpecifier = #"%(?:\d+\$)?(?:lld|ld|d|@|lf|f)"#

    /// Calls whose leading string literal is a localization key.
    private static let keyOpener = try! NSRegularExpression(pattern: #"(?<![\w.])(?:Text|Button|Label|TextField|ProgressView|DisclosureGroup|Toggle|Picker|Menu|LocalizedStringKey|sectionHeader)\(|\.(?:help|alert|accessibilityLabel|value)\(|String\(localized:\s*|(?<![\w.])(?:title|label):\s*(?=")"#)

    private static func ascii(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }

    private static let quote = ascii("\"")
    private static let backslash = ascii("\\")
    private static let openParen = ascii("(")
    private static let closeParen = ascii(")")

    private static func localizationKeys(in text: String) -> [SourceKey] {
        let units = Array(text.utf16)
        let string = text as NSString
        var keys: [SourceKey] = []

        for match in keyOpener.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            // Notification titles are plain `String`s, not keys.
            let lookback = max(0, match.range.location - 120)
            if string.substring(with: NSRange(location: lookback, length: match.range.location - lookback))
                .contains("showNotification(") {
                continue
            }

            var index = skipWhitespace(units, from: match.range.location + match.range.length)
            guard index < units.count else { continue }

            if units[index] == quote {
                if let literal = readLiteral(units, from: index) { keys.append(literal.key) }
                continue
            }

            // `condition ? "a" : "b"` as the first argument.
            while index < units.count, units[index] != ascii(","), units[index] != closeParen {
                if units[index] == quote {
                    index = readLiteral(units, from: index)?.end ?? units.count
                    continue
                }
                if units[index] == openParen {
                    break
                }
                if units[index] == ascii("?") {
                    let first = skipWhitespace(units, from: index + 1)
                    guard first < units.count, units[first] == quote,
                          let whenTrue = readLiteral(units, from: first) else { break }
                    let colon = skipWhitespace(units, from: whenTrue.end)
                    guard colon < units.count, units[colon] == ascii(":") else { break }
                    let second = skipWhitespace(units, from: colon + 1)
                    guard second < units.count, units[second] == quote,
                          let whenFalse = readLiteral(units, from: second) else { break }
                    keys += [whenTrue.key, whenFalse.key]
                    break
                }
                index += 1
            }
        }

        return keys.filter { $0 != .exact("") }
    }

    private static func skipWhitespace(_ units: [UInt16], from start: Int) -> Int {
        var index = start
        while index < units.count, [ascii(" "), ascii("\t"), ascii("\n")].contains(units[index]) {
            index += 1
        }
        return index
    }

    /// Reads the string literal starting at `start`, returning its key and the index after it.
    private static func readLiteral(_ units: [UInt16], from start: Int) -> (key: SourceKey, end: Int)? {
        var index = start + 1
        var exact = ""
        var pattern = ""
        var buffer: [UInt16] = []
        var interpolates = false

        func flush() {
            let piece = String(decoding: buffer, as: UTF16.self)
            exact += piece
            pattern += NSRegularExpression.escapedPattern(for: piece)
            buffer.removeAll()
        }

        while index < units.count {
            let unit = units[index]
            if unit == backslash, index + 1 < units.count {
                let next = units[index + 1]
                if next == openParen {
                    flush()
                    pattern += formatSpecifier
                    interpolates = true
                    var depth = 1
                    index += 2
                    while index < units.count, depth > 0 {
                        if units[index] == openParen { depth += 1 }
                        if units[index] == closeParen { depth -= 1 }
                        index += 1
                    }
                    continue
                }
                switch next {
                case ascii("n"): buffer.append(ascii("\n"))
                case ascii("t"): buffer.append(ascii("\t"))
                default: buffer.append(next)
                }
                index += 2
                continue
            }
            if unit == quote {
                flush()
                return (interpolates ? .pattern(pattern) : .exact(exact), index + 1)
            }
            buffer.append(unit)
            index += 1
        }
        return nil
    }
}
