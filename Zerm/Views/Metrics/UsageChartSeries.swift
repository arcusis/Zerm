import Foundation

/// Everything the usage charts need that is a pure function of their buckets.
///
/// Chart selection follows the pointer, so anything the view derives inside its own body is
/// derived again every time the cursor moves — and the rate series, the peak bucket and the
/// nearest-bucket lookup are all O(n). Worse, the old nearest-bucket search was read from
/// inside the mark builders, making it O(n) per plotted element. Deriving it all once, when
/// the buckets themselves change, is what keeps the dashboard smooth under a fast scroll.
struct UsageChartSeries: Equatable {
    let buckets: [UsageBucket]
    let ratePoints: [RatePoint]
    /// `nil` when nothing was dictated in the window, so no peak is worth labelling.
    let peakBucketID: Date?
    let xDomain: ClosedRange<Date>

    private let indexByStart: [Date: Int]

    /// A dictation rate only exists for buckets that actually recorded audio.
    struct RatePoint: Identifiable, Equatable {
        let start: Date
        let wordsPerMinute: Double
        /// Each unbroken run is its own series, so the line stops at a gap instead of drawing
        /// straight through days the user never opened Zerm.
        let run: Int
        let isIsolated: Bool
        var isLast: Bool = false

        var id: Date { start }
    }

    static let empty = UsageChartSeries(buckets: [], unit: .day)

    init(buckets: [UsageBucket], unit: Calendar.Component, calendar: Calendar = .current) {
        self.buckets = buckets
        self.ratePoints = Self.ratePoints(in: buckets)
        self.indexByStart = Dictionary(
            uniqueKeysWithValues: buckets.enumerated().map { ($1.start, $0) }
        )

        let peak = buckets.max { $0.totals.words < $1.totals.words }
        self.peakBucketID = (peak?.totals.words ?? 0) > 0 ? peak?.id : nil

        // Both charts are pinned to the same window so the two plots line up even when the
        // rate series has fewer points than the bars.
        if let first = buckets.first?.start, let last = buckets.last?.start {
            let end = calendar.date(byAdding: unit, value: 1, to: last) ?? last
            self.xDomain = first...max(first, end)
        } else {
            let today = calendar.startOfDay(for: Date())
            self.xDomain = today...today
        }
    }

    var isEmpty: Bool { buckets.isEmpty }

    var hasRateSeries: Bool { !ratePoints.isEmpty }

    func bucket(startingAt start: Date?) -> UsageBucket? {
        guard let start, let index = indexByStart[start] else { return nil }
        return buckets[index]
    }

    /// Binary search rather than a linear scan: this runs on the hover path, where the
    /// pointer can produce a lookup per mouse event.
    func nearestStart(to date: Date) -> Date? {
        guard let first = buckets.first else { return nil }
        guard buckets.count > 1 else { return first.start }

        var low = 0
        var high = buckets.count - 1
        while low < high {
            let mid = low + (high - low) / 2
            if buckets[mid].start < date {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let candidate = buckets[low].start
        guard low > 0 else { return candidate }

        let previous = buckets[low - 1].start
        return abs(previous.timeIntervalSince(date)) <= abs(candidate.timeIntervalSince(date))
            ? previous
            : candidate
    }

    private static func ratePoints(in buckets: [UsageBucket]) -> [RatePoint] {
        var runs: [[UsageBucket]] = []
        for bucket in buckets {
            guard bucket.totals.recordedSeconds > 0 else {
                if runs.last?.isEmpty == false { runs.append([]) }
                continue
            }
            if runs.isEmpty { runs.append([]) }
            runs[runs.count - 1].append(bucket)
        }

        var points: [RatePoint] = []
        for (index, run) in runs.enumerated() where !run.isEmpty {
            for bucket in run {
                points.append(RatePoint(
                    start: bucket.start,
                    wordsPerMinute: bucket.totals.wordsPerMinute,
                    run: index,
                    isIsolated: run.count == 1
                ))
            }
        }
        if !points.isEmpty {
            points[points.count - 1].isLast = true
        }
        return points
    }
}
