import Foundation
import SwiftData
import OSLog

extension Notification.Name {
    static let usageStatsUpdated = Notification.Name("usageStatsUpdated")
}

/// Durable, aggregate-only usage statistics.
///
/// Every dashboard number comes from here rather than from surviving `Transcription`
/// rows, so transcript retention cannot erase the user's history. See `UsageDay`.
@MainActor
final class UsageStatsService {
    static let shared = UsageStatsService()

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "UsageStatsService")
    private var container: ModelContainer?

    private static let backfillVersionKey = "UsageStatsBackfillVersion"
    private static let backfillVersion = 1

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Recording

    func record(
        words: Int,
        recordedSeconds: Double,
        transcribeSeconds: Double,
        enhanceSeconds: Double,
        wasEnhanced: Bool
    ) {
        apply(.session(
            words: words,
            recordedSeconds: recordedSeconds,
            transcribeSeconds: transcribeSeconds,
            enhanceSeconds: enhanceSeconds,
            wasEnhanced: wasEnhanced
        ))
    }

    /// Convenience for the dictation pipeline, which already holds the finished record.
    func record(_ transcription: Transcription) {
        record(
            words: WordCounter.count(in: transcription.text),
            recordedSeconds: transcription.duration,
            transcribeSeconds: transcription.transcriptionDuration ?? 0,
            enhanceSeconds: transcription.enhancementDuration ?? 0,
            // A failed enhancement leaves `enhancedText` alone, and the language guard can
            // store the original transcript as the "enhancement". Only a recorded duration
            // means the model actually ran to completion.
            wasEnhanced: transcription.enhancementDuration != nil
        )
    }

    func recordReadAloud(words: Int) {
        apply(.readAloud(words: words))
    }

    /// Counted separately from `record(_:)` because in Instant + Refine the session is
    /// recorded at paste time and the enhancement only lands a few seconds later.
    func recordDeferredEnhancement(seconds: Double) {
        apply(.deferredEnhancement(seconds: seconds))
    }

    private func apply(_ delta: UsageTotals) {
        guard let context = container?.mainContext else { return }

        let day = Self.startOfDay(for: Date())
        do {
            let existing = try context.fetch(
                FetchDescriptor<UsageDay>(predicate: #Predicate { $0.day == day })
            ).first

            if let existing {
                existing.add(delta)
            } else {
                context.insert(UsageDay(day: day, totals: delta))
            }
            try context.save()
            NotificationCenter.default.post(name: .usageStatsUpdated, object: nil)
        } catch {
            logger.error("Failed to record usage: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes every recorded day.
    ///
    /// Before statistics were durable they were derived from the transcript table, so
    /// clearing history happened to clear them too. Keeping them across a deletion is the
    /// point of this store, but it would otherwise leave no way at all to erase them —
    /// so the ability has to exist explicitly rather than as a side effect.
    ///
    /// The backfill marker is left set on purpose: a later re-backfill would repopulate
    /// the store from surviving transcripts, which is the opposite of what was asked for.
    func resetAll() {
        guard let context = container?.mainContext else { return }
        do {
            try context.delete(model: UsageDay.self)
            try context.save()
            // Read Aloud also keeps its own monotonic counters, which predate this store
            // and feed the same dashboard cards.
            TTSSettings.resetCounters()
            NotificationCenter.default.post(name: .usageStatsUpdated, object: nil)
            logger.notice("Usage statistics cleared at the user's request")
        } catch {
            logger.error("Failed to clear usage statistics: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reading

    func days(in range: ClosedRange<Date>) -> [UsageDay] {
        guard let context = container?.mainContext else { return [] }

        let lower = range.lowerBound
        let upper = range.upperBound
        let descriptor = FetchDescriptor<UsageDay>(
            predicate: #Predicate { $0.day >= lower && $0.day <= upper },
            sortBy: [SortDescriptor(\.day)]
        )

        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch usage days: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func allDays() -> [UsageDay] {
        guard let context = container?.mainContext else { return [] }

        do {
            return try context.fetch(
                FetchDescriptor<UsageDay>(sortBy: [SortDescriptor(\.day)])
            )
        } catch {
            logger.error("Failed to fetch usage days: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func allTimeTotals() -> UsageTotals {
        Self.sum(allDays())
    }

    // MARK: - Backfill

    /// One-time pass over the transcripts that are still on disk, bucketed by the day
    /// they were recorded. History deleted by an earlier retention sweep is gone for
    /// good — this only rescues what survives at the moment of upgrade.
    func backfillIfNeeded(from transcriptContext: ModelContext) async {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.backfillVersionKey) < Self.backfillVersion else { return }

        let container = transcriptContext.container
        let calendar = Calendar.current
        let legacyReadAloudWords = defaults.integer(forKey: TTSSettings.Keys.wordsReadAloud)
        let legacyReadAloudSessions = defaults.integer(forKey: TTSSettings.Keys.sessionsReadAloud)

        do {
            let bucketCount = try await Task.detached(priority: .utility) {
                // Both stores live in one container, so a single background context can read
                // transcripts and write the aggregates.
                let context = ModelContext(container)

                var descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { $0.transcriptionStatus == "completed" }
                )
                descriptor.propertiesToFetch = [
                    \.text, \.timestamp, \.duration, \.transcriptionDuration, \.enhancementDuration
                ]

                var buckets: [Date: UsageTotals] = [:]
                try context.enumerate(descriptor) { transcription in
                    let day = calendar.startOfDay(for: transcription.timestamp)
                    let delta = UsageTotals.session(
                        words: WordCounter.count(in: transcription.text),
                        recordedSeconds: transcription.duration,
                        transcribeSeconds: transcription.transcriptionDuration ?? 0,
                        enhanceSeconds: transcription.enhancementDuration ?? 0,
                        wasEnhanced: transcription.enhancementDuration != nil
                    )
                    buckets[day] = (buckets[day] ?? UsageTotals()).adding(delta)
                }

                // Read Aloud only ever kept running `UserDefaults` totals with no per-day
                // history, so its lifetime numbers land on the day of the upgrade. They are
                // not part of any chart, only the all-time card.
                if legacyReadAloudWords > 0 || legacyReadAloudSessions > 0 {
                    let today = calendar.startOfDay(for: Date())
                    var totals = buckets[today] ?? UsageTotals()
                    totals.readAloudWords += legacyReadAloudWords
                    totals.readAloudSessions += legacyReadAloudSessions
                    buckets[today] = totals
                }

                for (day, totals) in buckets {
                    let existing = try context.fetch(
                        FetchDescriptor<UsageDay>(predicate: #Predicate { $0.day == day })
                    ).first
                    if let existing {
                        existing.add(totals)
                    } else {
                        context.insert(UsageDay(day: day, totals: totals))
                    }
                }

                try context.save()
                return buckets.count
            }.value
            defaults.set(Self.backfillVersion, forKey: Self.backfillVersionKey)
            logger.notice("Backfilled usage stats for \(bucketCount, privacy: .public) day(s)")

            NotificationCenter.default.post(name: .usageStatsUpdated, object: nil)
        } catch {
            logger.error("Usage stats backfill failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pure helpers

    nonisolated static func startOfDay(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    static func sum(_ days: [UsageDay]) -> UsageTotals {
        days.reduce(into: UsageTotals()) { $0.add($1.totals) }
    }

    /// Consecutive days ending today that have at least one session. A day still counts
    /// as unbroken until it is fully missed, so a streak survives until tomorrow rather
    /// than reading zero every morning.
    nonisolated static func currentStreak(activeDays: Set<Date>, today: Date, calendar: Calendar = .current) -> Int {
        let todayStart = calendar.startOfDay(for: today)
        var cursor: Date
        if activeDays.contains(todayStart) {
            cursor = todayStart
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
                  activeDays.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    nonisolated static func longestStreak(activeDays: Set<Date>, calendar: Calendar = .current) -> Int {
        let sorted = activeDays.sorted()
        var longest = 0
        var run = 0
        var previous: Date?

        for day in sorted {
            if let previous,
               let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: day) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        return longest
    }
}
