import Foundation
import Testing
@testable import Zerm

struct UsageStatsTests {

    /// Fixed zone so the midnight boundary is the same wherever the suite runs.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Day bucketing

    @Test func bucketsSplitAtMidnight() {
        let lateNight = Self.date(2026, 3, 14, 23, 59)
        let justAfterMidnight = Self.date(2026, 3, 15, 0, 1)

        let first = UsageStatsService.startOfDay(for: lateNight, calendar: Self.calendar)
        let second = UsageStatsService.startOfDay(for: justAfterMidnight, calendar: Self.calendar)

        #expect(first != second)
        #expect(first == Self.date(2026, 3, 14))
        #expect(second == Self.date(2026, 3, 15))
    }

    @Test func bucketsShareADayAcrossItsWholeSpan() {
        let start = UsageStatsService.startOfDay(for: Self.date(2026, 3, 14, 0, 0), calendar: Self.calendar)
        let end = UsageStatsService.startOfDay(for: Self.date(2026, 3, 14, 23, 59), calendar: Self.calendar)

        #expect(start == end)
    }

    // MARK: - Upsert accumulation

    @Test func sessionsAccumulateIntoOneDay() {
        var day = UsageTotals()
        day.add(.session(words: 120, recordedSeconds: 60, transcribeSeconds: 2, enhanceSeconds: 0, wasEnhanced: false))
        day.add(.session(words: 80, recordedSeconds: 60, transcribeSeconds: 3, enhanceSeconds: 1.5, wasEnhanced: true))

        #expect(day.sessions == 2)
        #expect(day.words == 200)
        #expect(day.enhancedSessions == 1)
        #expect(day.recordedSeconds == 120)
        #expect(day.transcribeSeconds == 5)
        #expect(day.enhanceSeconds == 1.5)
    }

    @Test func readAloudAccumulatesWithoutTouchingDictation() {
        var day = UsageTotals()
        day.add(.session(words: 50, recordedSeconds: 30, transcribeSeconds: 1, enhanceSeconds: 0, wasEnhanced: false))
        day.add(.readAloud(words: 300))
        day.add(.readAloud(words: 200))

        #expect(day.sessions == 1)
        #expect(day.words == 50)
        #expect(day.readAloudSessions == 2)
        #expect(day.readAloudWords == 500)
    }

    @Test func derivedFiguresUseTheAccumulatedTotals() {
        var day = UsageTotals()
        day.add(.session(words: 200, recordedSeconds: 120, transcribeSeconds: 4, enhanceSeconds: 0, wasEnhanced: false))

        #expect(day.wordsPerMinute == 100)
        // 200 words at the 35 wpm typing baseline is 342.85s, less the 120s spent dictating.
        #expect(abs(day.timeSaved - (200.0 / 35.0 * 60.0 - 120.0)) < 0.001)
        #expect(day.keystrokesSaved == 1000)
    }

    @Test func emptyTotalsNeverReportNegativeTimeSaved() {
        var day = UsageTotals()
        day.add(.session(words: 1, recordedSeconds: 600, transcribeSeconds: 1, enhanceSeconds: 0, wasEnhanced: false))

        #expect(day.timeSaved == 0)
        #expect(UsageTotals().wordsPerMinute == 0)
    }

    // MARK: - Range totals

    /// What the dashboard does on reload: filter the rows to the range, bucket them, sum the buckets.
    private static func rangeTotals(_ range: UsageRange, days: [UsageDay], today: Date) -> UsageTotals {
        let inRange = UsageSeries.days(days, in: range, today: today, calendar: calendar)
        return UsageSeries.totals(UsageSeries.buckets(for: range, days: inRange, today: today, calendar: calendar))
    }

    @Test func rangeTotalsCountOnlyTheSelectedWindow() {
        let today = Self.date(2026, 3, 15, 12, 0)
        // Words per row, keyed by how many days before today it was recorded.
        let wordsByAge = [0: 700, 5: 350, 20: 1400, 200: 3500, 800: 7000]
        let days = wordsByAge.map { age, words in
            UsageDay(
                day: Self.calendar.date(byAdding: .day, value: -age, to: Self.date(2026, 3, 15))!,
                totals: .session(words: words, recordedSeconds: 60, transcribeSeconds: 1, enhanceSeconds: 0, wasEnhanced: false)
            )
        }

        let week = Self.rangeTotals(.week, days: days, today: today)
        let month = Self.rangeTotals(.month, days: days, today: today)
        let year = Self.rangeTotals(.year, days: days, today: today)
        let allTime = Self.rangeTotals(.allTime, days: days, today: today)

        #expect(week.sessions == 2)
        #expect(week.words == 1050)
        #expect(month.words == 2450)
        #expect(year.words == 5950)
        #expect(allTime.words == 12950)
        #expect(allTime.sessions == 5)

        // The hero's "time saved" is the range total: 1,050 words at 35 wpm is 1,800s, less the
        // 120s spent dictating.
        #expect(abs(week.timeSaved - 1680) < 0.001)
        #expect(week.timeSaved < month.timeSaved)
        #expect(allTime == days.reduce(into: UsageTotals()) { $0.add($1.totals) })
    }

    @Test func rangeTotalsAreEmptyWhenNothingFallsInside() {
        let today = Self.date(2026, 3, 15)
        let days = [UsageDay(
            day: Self.date(2025, 1, 1),
            totals: .session(words: 500, recordedSeconds: 60, transcribeSeconds: 1, enhanceSeconds: 0, wasEnhanced: false)
        )]

        #expect(Self.rangeTotals(.week, days: days, today: today) == UsageTotals())
        #expect(Self.rangeTotals(.month, days: days, today: today) == UsageTotals())
        #expect(Self.rangeTotals(.allTime, days: days, today: today).words == 500)
    }

    // MARK: - Streaks

    @Test func streakCountsConsecutiveDaysEndingToday() {
        let today = Self.date(2026, 3, 15)
        let activeDays: Set<Date> = [
            Self.date(2026, 3, 15),
            Self.date(2026, 3, 14),
            Self.date(2026, 3, 13)
        ]

        #expect(UsageStatsService.currentStreak(activeDays: activeDays, today: today, calendar: Self.calendar) == 3)
    }

    @Test func streakStopsAtTheFirstMissedDay() {
        let today = Self.date(2026, 3, 15)
        let activeDays: Set<Date> = [
            Self.date(2026, 3, 15),
            Self.date(2026, 3, 14),
            // 13th missed
            Self.date(2026, 3, 12),
            Self.date(2026, 3, 11)
        ]

        #expect(UsageStatsService.currentStreak(activeDays: activeDays, today: today, calendar: Self.calendar) == 2)
    }

    @Test func streakSurvivesADayThatIsNotOverYet() {
        let today = Self.date(2026, 3, 15, 9, 0)
        let activeDays: Set<Date> = [
            Self.date(2026, 3, 14),
            Self.date(2026, 3, 13)
        ]

        #expect(UsageStatsService.currentStreak(activeDays: activeDays, today: today, calendar: Self.calendar) == 2)
    }

    @Test func streakIsZeroAfterAFullMissedDay() {
        let today = Self.date(2026, 3, 15)
        let activeDays: Set<Date> = [
            Self.date(2026, 3, 13),
            Self.date(2026, 3, 12)
        ]

        #expect(UsageStatsService.currentStreak(activeDays: activeDays, today: today, calendar: Self.calendar) == 0)
        #expect(UsageStatsService.currentStreak(activeDays: [], today: today, calendar: Self.calendar) == 0)
    }

    @Test func longestStreakFindsThePastRun() {
        let activeDays: Set<Date> = [
            Self.date(2026, 3, 1),
            Self.date(2026, 3, 2),
            Self.date(2026, 3, 3),
            Self.date(2026, 3, 4),
            // gap
            Self.date(2026, 3, 10),
            Self.date(2026, 3, 11)
        ]

        #expect(UsageStatsService.longestStreak(activeDays: activeDays, calendar: Self.calendar) == 4)
        #expect(UsageStatsService.longestStreak(activeDays: [], calendar: Self.calendar) == 0)
    }
}
