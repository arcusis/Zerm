import Foundation

enum ClipboardRetentionPeriod: Codable, Equatable, Sendable {
    case never
    case unlimited
    case days(Int)

    static let choices: [ClipboardRetentionPeriod] = [
        .never, .days(1), .days(7), .days(30), .days(90), .days(180), .days(365), .unlimited
    ]

    var dayCount: Int? {
        if case let .days(days) = self { return min(365, max(1, days)) }
        return nil
    }

    var storageValue: String {
        switch self {
        case .never: "never"
        case .unlimited: "unlimited"
        case let .days(days): "days:\(min(365, max(1, days)))"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "never": self = .never
        case "unlimited": self = .unlimited
        case "Never": self = .never
        case "Unlimited": self = .unlimited
        case "1 day": self = .days(1)
        case "3 days": self = .days(3)
        case "7 days": self = .days(7)
        case "14 days": self = .days(14)
        case "30 days": self = .days(30)
        case "90 days": self = .days(90)
        case "6 months": self = .days(180)
        case "1 year": self = .days(365)
        default:
            guard storageValue.hasPrefix("days:"),
                  let days = Int(storageValue.dropFirst(5)), (1...365).contains(days) else { return nil }
            self = .days(days)
        }
    }
}

struct ClipboardTag: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var colorHex: String

    init(id: UUID = UUID(), name: String, colorHex: String = "#808080") {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.colorHex = colorHex
    }
}

enum ClipboardHistorySort: String, CaseIterable, Sendable {
    case lastCopy
    case firstCopy
    case copyCount
    case size
    case copySequence
}

enum ClipboardHistoryEngineSettings {
    static func retentionPeriod(for kind: ClipboardItemKind) -> ClipboardRetentionPeriod {
        let values = UserDefaults.standard.dictionary(forKey: ClipboardHistorySettings.Keys.retentionByKind) as? [String: String] ?? [:]
        guard let value = values[kind.rawValue], let period = ClipboardRetentionPeriod(storageValue: value) else { return .days(90) }
        return period
    }

    static func setRetentionPeriod(_ period: ClipboardRetentionPeriod, for kind: ClipboardItemKind) {
        var values = UserDefaults.standard.dictionary(forKey: ClipboardHistorySettings.Keys.retentionByKind) as? [String: String] ?? [:]
        values[kind.rawValue] = period.storageValue
        UserDefaults.standard.set(values, forKey: ClipboardHistorySettings.Keys.retentionByKind)
    }

    static var sort: ClipboardHistorySort {
        get {
            let rawValue = UserDefaults.standard.string(forKey: ClipboardHistorySettings.Keys.sort) ?? ClipboardHistorySort.lastCopy.rawValue
            return ClipboardHistorySort(rawValue: rawValue) ?? .lastCopy
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ClipboardHistorySettings.Keys.sort) }
    }

    static var copyMergeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: ClipboardHistorySettings.Keys.copyMergeEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: ClipboardHistorySettings.Keys.copyMergeEnabled) }
    }

    static var copyMergeSeparator: String {
        get { UserDefaults.standard.string(forKey: ClipboardHistorySettings.Keys.copyMergeSeparator) == " " ? " " : "\n" }
        set { UserDefaults.standard.set(newValue == " " ? " " : "\n", forKey: ClipboardHistorySettings.Keys.copyMergeSeparator) }
    }

    static var copyMergeUpdatesClipboard: Bool {
        get { UserDefaults.standard.bool(forKey: ClipboardHistorySettings.Keys.copyMergeUpdatesClipboard) }
        set { UserDefaults.standard.set(newValue, forKey: ClipboardHistorySettings.Keys.copyMergeUpdatesClipboard) }
    }

    static func shouldCapture(_ kind: ClipboardItemKind) -> Bool {
        retentionPeriod(for: kind) != .never
    }
}

enum ClipboardHistoryCaptureError: Error {
    case retentionDisabled
}
