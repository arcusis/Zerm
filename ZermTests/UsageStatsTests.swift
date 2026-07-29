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
