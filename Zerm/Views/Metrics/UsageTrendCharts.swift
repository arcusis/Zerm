import SwiftUI
import Charts

/// Words dictated per bucket, and the words-per-minute trend across the same buckets.
///
/// Two stacked charts rather than one chart with two y-scales: words and words-per-minute
/// have unrelated ranges, and overlaying them on separate axes invents a correlation that
/// is not in the data. They share an x-domain instead, so the eye still reads them together.
struct UsageTrendCharts: View {
    let range: UsageRange
    let buckets: [UsageBucket]

    @State private var selectedDate: Date?
    @State private var isTableExpanded = false

    private var selectedBucket: UsageBucket? {
        guard let selectedDate else { return nil }
        return buckets.min {
            abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate))
        }
    }

    private var peakBucket: UsageBucket? {
        buckets.max { $0.totals.words < $1.totals.words }
    }

    private var lastRateBucket: UsageBucket? {
        buckets.last { $0.totals.recordedSeconds > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            chartCard(
                title: "Words Dictated",
                subtitle: range.caption,
                readout: selectedBucket.map { "\(UsageFormatters.number($0.totals.words)) words" }
            ) {
                wordsChart
            }

            if lastRateBucket != nil {
                chartCard(
                    title: "Words Per Minute",
                    subtitle: "Dictation speed, \(range.caption.lowercased())",
                    readout: selectedBucket.flatMap { bucket in
                        bucket.totals.recordedSeconds > 0
                            ? String(format: "%.0f wpm", bucket.totals.wordsPerMinute)
                            : "No dictation"
                    }
                ) {
                    rateChart
                }
            }

            DisclosureGroup("Show data table", isExpanded: $isTableExpanded) {
                UsageDataTable(range: range, buckets: buckets)
                    .padding(.top, 10)
            }
            .font(.system(size: 12))
        }
    }

    // MARK: - Charts

    private var wordsChart: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Date", bucket.start, unit: bucketUnit),
                y: .value("Words", bucket.totals.words),
                width: .ratio(0.68)
            )
            .foregroundStyle(UsageChartPalette.words)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 4,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 4,
                    style: .continuous
                )
            )

            if let peakBucket, peakBucket.totals.words > 0, peakBucket.id == bucket.id, selectedBucket == nil {
                PointMark(
                    x: .value("Date", bucket.start, unit: bucketUnit),
                    y: .value("Words", bucket.totals.words)
                )
                .opacity(0)
                .annotation(position: .top, spacing: 4) {
                    Text(UsageFormatters.number(bucket.totals.words))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .chartXSelection(value: $selectedDate)
        .chartOverlay { proxy in
            selectionRule(proxy: proxy)
        }
        .frame(height: 150)
    }

    private var rateChart: some View {
        Chart(ratePoints) { point in
            LineMark(
                x: .value("Date", point.start, unit: bucketUnit),
                y: .value("Words per minute", point.wordsPerMinute),
                // Each unbroken run is its own series, so the line stops at a gap instead
                // of drawing straight through days the user never opened Zerm.
                series: .value("Run", point.run)
            )
            .foregroundStyle(UsageChartPalette.rate)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)

            if point.isIsolated || point.isLast {
                PointMark(
                    x: .value("Date", point.start, unit: bucketUnit),
                    y: .value("Words per minute", point.wordsPerMinute)
                )
                .symbolSize(64)
                .foregroundStyle(UsageChartPalette.rate)
                .annotation(position: .top, spacing: 4) {
                    if point.isLast && selectedBucket == nil {
                        Text(String(format: "%.0f", point.wordsPerMinute))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .chartXSelection(value: $selectedDate)
        .chartOverlay { proxy in
            selectionRule(proxy: proxy)
        }
        .frame(height: 120)
    }

    /// A dictation rate only exists for buckets that actually recorded audio.
    private struct RatePoint: Identifiable {
        let start: Date
        let wordsPerMinute: Double
        let run: Int
        let isIsolated: Bool
        var isLast: Bool = false

        var id: Date { start }
    }

    private var ratePoints: [RatePoint] {
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

    /// Both charts are pinned to the same window so the two plots line up even when the
    /// rate series has fewer points than the bars.
    private var xDomain: ClosedRange<Date> {
        guard let first = buckets.first?.start, let last = buckets.last?.start else {
            let today = Date()
            return today...today
        }
        let calendar = Calendar.current
        let end = calendar.date(byAdding: bucketUnit, value: 1, to: last) ?? last
        return first...end
    }

    /// A shared crosshair drawn as an overlay rather than a `RuleMark`, so both charts
    /// track the same selection without either of them owning it.
    @ViewBuilder
    private func selectionRule(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let selectedBucket,
               let plotFrame = proxy.plotFrame,
               let offset = proxy.position(forX: selectedBucket.start) {
                let frame = geometry[plotFrame]
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 1, height: frame.height)
                    .position(x: frame.origin.x + offset, y: frame.midY)
            }
        }
    }

    private var bucketUnit: Calendar.Component {
        range.isMonthly ? .month : .day
    }

    private var xLabelFormat: Date.FormatStyle {
        range.isMonthly
            ? .dateTime.month(.abbreviated)
            : .dateTime.month(.abbreviated).day()
    }

    private var xAxis: some AxisContent {
        AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { _ in
            AxisValueLabel(format: xLabelFormat)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
        }
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
            AxisGridLine()
                .foregroundStyle(Color.secondary.opacity(0.14))
            AxisValueLabel()
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
        }
    }

    // MARK: - Card chrome

    private func chartCard<Content: View>(
        title: String,
        subtitle: String,
        readout: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let selectedBucket {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(bucketLabel(selectedBucket.start))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(readout ?? "–")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
    }

    private func bucketLabel(_ date: Date) -> String {
        date.formatted(range.isMonthly
            ? .dateTime.month(.abbreviated).year()
            : .dateTime.month(.abbreviated).day())
    }
}

/// The text twin of the charts: every plotted value in writing, so no number is
/// reachable only by hovering.
private struct UsageDataTable: View {
    let range: UsageRange
    let buckets: [UsageBucket]

    private var rows: [UsageBucket] {
        buckets.filter { $0.totals.sessions > 0 }.reversed()
    }

    var body: some View {
        if rows.isEmpty {
            Text("No sessions in this period.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                header
                ForEach(rows) { bucket in
                    row(bucket)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(range.isMonthly ? "Month" : "Day")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Sessions").frame(width: 70, alignment: .trailing)
            Text("Words").frame(width: 70, alignment: .trailing)
            Text("WPM").frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.secondary)
        .padding(.vertical, 6)
    }

    private func row(_ bucket: UsageBucket) -> some View {
        HStack {
            Text(bucket.start.formatted(range.isMonthly
                ? .dateTime.month(.abbreviated).year()
                : .dateTime.month(.abbreviated).day()))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(bucket.totals.sessions)").frame(width: 70, alignment: .trailing)
            Text(UsageFormatters.number(bucket.totals.words)).frame(width: 70, alignment: .trailing)
            Text(bucket.totals.recordedSeconds > 0
                ? String(format: "%.0f", bucket.totals.wordsPerMinute)
                : "–")
                .frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.vertical, 3)
    }
}
