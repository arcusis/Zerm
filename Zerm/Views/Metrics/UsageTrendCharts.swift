import SwiftUI
import Charts

/// Words dictated per bucket, and the words-per-minute trend across the same buckets.
///
/// Two stacked charts rather than one chart with two y-scales: words and words-per-minute
/// have unrelated ranges, and overlaying them on separate axes invents a correlation that
/// is not in the data. They share an x-domain instead, so the eye still reads them together.
///
/// Everything derived from the buckets arrives precomputed in `UsageChartSeries`. Nothing on
/// the hover path may allocate or scan: selection follows the pointer, and the pointer moves
/// across these charts every time the dashboard is scrolled.
struct UsageTrendCharts: View {
    let range: UsageRange
    let series: UsageChartSeries

    @State private var selectedStart: Date?
    @State private var isTableExpanded = false

    private var selectedBucket: UsageBucket? {
        series.bucket(startingAt: selectedStart)
    }

    /// Selection is stored snapped to a bucket, and only written when the bucket actually
    /// changes. Swift Charts hands over a continuous date for every pointer event, so
    /// binding it straight to state rewrote it dozens of times a second — rebuilding both
    /// charts each time — while the pointer sat inside a single bar.
    private var selectionBinding: Binding<Date?> {
        Binding(
            get: { selectedStart },
            set: { proposed in
                let snapped = proposed.flatMap { series.nearestStart(to: $0) }
                if snapped != selectedStart {
                    selectedStart = snapped
                }
            }
        )
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

            if series.hasRateSeries {
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
                UsageDataTable(range: range, buckets: series.buckets)
                    .padding(.top, 10)
            }
            .font(.system(size: 12))
        }
        .onChange(of: series) { _, updated in
            // A reload that only moved today's totals should not throw away the hover; a
            // range switch, which replaces the buckets outright, has to.
            if let selectedStart, updated.bucket(startingAt: selectedStart) == nil {
                self.selectedStart = nil
            }
        }
    }

    // MARK: - Charts

    private var wordsChart: some View {
        // Read once, outside the mark builder: anything referenced inside it is evaluated
        // per plotted element.
        let peakID = selectedStart == nil ? series.peakBucketID : nil

        return Chart(series.buckets) { bucket in
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

            if peakID == bucket.id {
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
        .chartXScale(domain: series.xDomain)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .chartXSelection(value: selectionBinding)
        .chartOverlay { proxy in
            selectionRule(proxy: proxy)
        }
        .frame(height: 150)
    }

    private var rateChart: some View {
        let labelsLastPoint = selectedStart == nil

        return Chart(series.ratePoints) { point in
            LineMark(
                x: .value("Date", point.start, unit: bucketUnit),
                y: .value("Words per minute", point.wordsPerMinute),
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
                    if point.isLast && labelsLastPoint {
                        Text(String(format: "%.0f", point.wordsPerMinute))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .chartXScale(domain: series.xDomain)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
        .chartXSelection(value: selectionBinding)
        .chartOverlay { proxy in
            selectionRule(proxy: proxy)
        }
        .frame(height: 120)
    }

    /// A shared crosshair drawn as an overlay rather than a `RuleMark`, so both charts
    /// track the same selection without either of them owning it.
    @ViewBuilder
    private func selectionRule(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let selectedStart,
               let plotFrame = proxy.plotFrame,
               let offset = proxy.position(forX: selectedStart) {
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
        .metricsCardSurface()
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
    private let rows: [UsageBucket]

    init(range: UsageRange, buckets: [UsageBucket]) {
        self.range = range
        // Filtered once here rather than per body pass — on All Time this is one row per
        // active day, and the table lives inside the dashboard's own scroll view.
        self.rows = Array(buckets.filter { $0.totals.sessions > 0 }.reversed())
    }

    var body: some View {
        if rows.isEmpty {
            Text("No sessions in this period.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVStack(spacing: 0) {
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
