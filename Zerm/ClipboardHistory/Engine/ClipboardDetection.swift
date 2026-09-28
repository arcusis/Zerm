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
