import Foundation
import SwiftUI
import AppKit

/// The window the dashboard is showing. Daily buckets stay readable up to a month;
/// past that the series is rolled up to months so the bars do not collapse into a comb.
enum UsageRange: String, CaseIterable, Identifiable {
    case week
    case month
    case year
    case allTime

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .week: return "7 Days"
        case .month: return "30 Days"
        case .year: return "12 Months"
        case .allTime: return "All Time"
        }
    }

    var caption: LocalizedStringResource {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .year: return "Last 12 months"
        case .allTime: return "All time"
        }
    }

    var isMonthly: Bool {
        self == .year || self == .allTime
    }
}

/// One plotted point: a day or a month, with everything that happened inside it.
struct UsageBucket: Identifiable, Equatable {
    let start: Date
    let totals: UsageTotals

    var id: Date { start }
}

enum UsageSeries {
    /// Buckets `days` across `range`, filling the gaps with zeroes so the x-axis stays
    /// continuous — a day with no dictation must read as a hole, not vanish and pull the
    /// neighbouring bars together.
    static func buckets(
        for range: UsageRange,
        days: [UsageDay],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [UsageBucket] {
        let component: Calendar.Component = range.isMonthly ? .month : .day
        guard let end = periodStart(for: today, component: component, calendar: calendar) else { return [] }

        let sums = Dictionary(
            days.map { (periodStart(for: $0.day, component: component, calendar: calendar) ?? $0.day, $0.totals) },
            uniquingKeysWith: { $0.adding($1) }
        )

        guard let start = firstPeriod(
            for: range,
            end: end,
            earliest: sums.keys.min(),
            component: component,
            calendar: calendar
        ) else { return [] }

        var buckets: [UsageBucket] = []
        var cursor = start
        while cursor <= end {
            buckets.append(UsageBucket(start: cursor, totals: sums[cursor] ?? UsageTotals()))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            cursor = next
        }
        return buckets
    }

    static func totals(_ buckets: [UsageBucket]) -> UsageTotals {
        buckets.reduce(into: UsageTotals()) { $0.add($1.totals) }
    }

    /// The rows of `days` that fall inside `range`. All Time keeps every row.
    static func days(
        _ days: [UsageDay],
        in range: UsageRange,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [UsageDay] {
        guard let window = fetchRange(for: range, today: today, calendar: calendar) else { return days }
        return days.filter { window.contains($0.day) }
    }

    /// The inclusive day range a `UsageDay` fetch should cover for `range`.
    static func fetchRange(
        for range: UsageRange,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> ClosedRange<Date>? {
        let end = calendar.startOfDay(for: today)
        switch range {
        case .week:
            guard let start = calendar.date(byAdding: .day, value: -6, to: end) else { return nil }
            return start...end
        case .month:
            guard let start = calendar.date(byAdding: .day, value: -29, to: end) else { return nil }
            return start...end
        case .year:
            guard let monthStart = periodStart(for: end, component: .month, calendar: calendar),
                  let start = calendar.date(byAdding: .month, value: -11, to: monthStart) else { return nil }
            return start...end
        case .allTime:
            return nil
        }
    }

    private static func periodStart(
        for date: Date,
        component: Calendar.Component,
        calendar: Calendar
    ) -> Date? {
        switch component {
        case .month:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: date))
        default:
            return calendar.startOfDay(for: date)
        }
    }

    private static func firstPeriod(
        for range: UsageRange,
        end: Date,
        earliest: Date?,
        component: Calendar.Component,
        calendar: Calendar
    ) -> Date? {
        switch range {
        case .week:
            return calendar.date(byAdding: .day, value: -6, to: end)
        case .month:
            return calendar.date(byAdding: .day, value: -29, to: end)
        case .year:
            return calendar.date(byAdding: .month, value: -11, to: end)
        case .allTime:
            // A brand-new install has no history at all; show the current period alone
            // rather than an empty plot.
            guard let earliest, earliest < end else { return end }
            // Cap the sweep so a stray far-past timestamp cannot generate thousands of
            // empty buckets.
            let limit = calendar.date(byAdding: .year, value: -10, to: end) ?? earliest
            return max(earliest, limit)
        }
    }
}

/// Every figure on the dashboard is formatted for the app's language, so a Hebrew UI never
/// shows English units or separators.
enum UsageFormatters {
    static func number(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    static func decimal(_ value: Double, fractionLength: Int, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(fractionLength)).locale(locale))
    }

    /// `nil` for a zero or negative interval, so callers choose their own wording for "nothing".
    static func duration(
        _ interval: TimeInterval,
        width: Duration.UnitsFormatStyle.UnitWidth,
        locale: Locale = .current
    ) -> String? {
        guard interval > 0 else { return nil }
        let units: Set<Duration.UnitsFormatStyle.Unit> = interval >= 3600 ? [.hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(interval)
            .formatted(.units(allowed: units, width: width, maximumUnitCount: 2).locale(locale))
    }

    static func seconds(_ interval: TimeInterval, fractionLength: Int, locale: Locale = .current) -> String {
        Duration.seconds(interval).formatted(
            .units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: fractionLength))
                .locale(locale)
        )
    }
}

/// Chart colours, validated against the light and dark chart surfaces for lightness,
/// chroma, colour-vision separation and 3:1 contrast. They are fixed rather than
/// taken from the accent colour so the two series never collide on a custom accent.
enum UsageChartPalette {
    static let words = dynamic(light: 0x007AFF, dark: 0x0A84FF)
    static let rate = dynamic(light: 0xC2610A, dark: 0xCE7F24)

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
