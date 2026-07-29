import Foundation
import SwiftData

/// One calendar day of aggregate usage.
///
/// This lives in its own `usage.store`, deliberately apart from `Transcription`.
/// Transcript retention (`TranscriptionAutoCleanupService`) hard-deletes transcript
/// rows on a timer, and the dashboard used to recompute every number by scanning
/// those rows — so lifetime metrics evaporated with the history. A separate store
/// means retention can never reach the metrics. Nothing here is transcript content,
/// only counts and durations, so it stays safe to keep even under zero retention.
@Model
final class UsageDay {
    @Attribute(.unique) var day: Date
    var sessions: Int
    var words: Int
    var enhancedSessions: Int
    var recordedSeconds: Double
    var transcribeSeconds: Double
    var enhanceSeconds: Double
    var readAloudWords: Int
    var readAloudSessions: Int

    init(day: Date, totals: UsageTotals = UsageTotals()) {
        self.day = day
        self.sessions = totals.sessions
        self.words = totals.words
        self.enhancedSessions = totals.enhancedSessions
        self.recordedSeconds = totals.recordedSeconds
        self.transcribeSeconds = totals.transcribeSeconds
        self.enhanceSeconds = totals.enhanceSeconds
        self.readAloudWords = totals.readAloudWords
        self.readAloudSessions = totals.readAloudSessions
    }

    var totals: UsageTotals {
        UsageTotals(
            sessions: sessions,
            words: words,
            enhancedSessions: enhancedSessions,
            recordedSeconds: recordedSeconds,
            transcribeSeconds: transcribeSeconds,
            enhanceSeconds: enhanceSeconds,
            readAloudWords: readAloudWords,
            readAloudSessions: readAloudSessions
        )
    }

    func add(_ delta: UsageTotals) {
        sessions += delta.sessions
        words += delta.words
        enhancedSessions += delta.enhancedSessions
        recordedSeconds += delta.recordedSeconds
        transcribeSeconds += delta.transcribeSeconds
        enhanceSeconds += delta.enhanceSeconds
        readAloudWords += delta.readAloudWords
        readAloudSessions += delta.readAloudSessions
    }
}

/// The additive shape of a `UsageDay`. Kept as a value type so summing a range,
/// bucketing a backfill and applying a single session all use the same arithmetic —
/// and so the maths is testable without a `ModelContainer`.
struct UsageTotals: Equatable {
    var sessions: Int = 0
    var words: Int = 0
    var enhancedSessions: Int = 0
    var recordedSeconds: Double = 0
    var transcribeSeconds: Double = 0
    var enhanceSeconds: Double = 0
    var readAloudWords: Int = 0
    var readAloudSessions: Int = 0

    static func session(
        words: Int,
        recordedSeconds: Double,
        transcribeSeconds: Double,
        enhanceSeconds: Double,
        wasEnhanced: Bool
    ) -> UsageTotals {
        UsageTotals(
            sessions: 1,
            words: words,
            enhancedSessions: wasEnhanced ? 1 : 0,
            recordedSeconds: recordedSeconds,
            transcribeSeconds: transcribeSeconds,
            enhanceSeconds: enhanceSeconds
        )
    }

    static func readAloud(words: Int) -> UsageTotals {
        UsageTotals(readAloudWords: words, readAloudSessions: 1)
    }

    /// Refine-in-place finishes after the session has already been counted, so the
    /// enhancement is added to that day separately rather than as a second session.
    static func deferredEnhancement(seconds: Double) -> UsageTotals {
        UsageTotals(enhancedSessions: 1, enhanceSeconds: seconds)
    }

    mutating func add(_ other: UsageTotals) {
        sessions += other.sessions
        words += other.words
        enhancedSessions += other.enhancedSessions
        recordedSeconds += other.recordedSeconds
        transcribeSeconds += other.transcribeSeconds
        enhanceSeconds += other.enhanceSeconds
        readAloudWords += other.readAloudWords
        readAloudSessions += other.readAloudSessions
    }

    func adding(_ other: UsageTotals) -> UsageTotals {
        var copy = self
        copy.add(other)
        return copy
    }

    var wordsPerMinute: Double {
        guard recordedSeconds > 0 else { return 0 }
        return Double(words) / (recordedSeconds / 60.0)
    }

    /// Words the user would have typed by hand, at the 35 wpm baseline the
    /// dashboard has always used, minus the time actually spent dictating.
    var timeSaved: TimeInterval {
        max(Double(words) / 35.0 * 60.0 - recordedSeconds, 0)
    }

    var keystrokesSaved: Int {
        Int(Double(words) * 5.0)
    }
}
