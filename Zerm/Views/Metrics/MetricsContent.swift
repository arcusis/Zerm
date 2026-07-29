import SwiftUI
import SwiftData

struct MetricsContent: View {
    @State private var range: UsageRange = .month
    @State private var buckets: [UsageBucket] = []
    @State private var rangeTotals = UsageTotals()
    @State private var allTimeTotals = UsageTotals()
    @State private var currentStreak: Int = 0
    @State private var longestStreak: Int = 0
    @State private var isLoadingMetrics = true

    var body: some View {
        Group {
            if isLoadingMetrics {
                ProgressView("Loading metrics...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allTimeTotals.sessions == 0 && allTimeTotals.readAloudSessions == 0 {
                emptyStateView
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 24) {
                            heroSection
                            rangePicker
                            metricsSection
                            UsageTrendCharts(range: range, buckets: buckets)

                            Spacer(minLength: 20)

                            HStack {
                                Spacer()
                                footerActionsView
                            }
                        }
                        .frame(minHeight: geometry.size.height - 56)
                        .padding(.vertical, 28)
                        .padding(.horizontal, 32)
                    }
                    .background(Color(.windowBackgroundColor))
                }
            }
        }
        .task {
            reload()
        }
        .onChange(of: range) { _, _ in
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .usageStatsUpdated)) { _ in
            reload()
        }
    }

    // MARK: - Loading

    private func reload() {
        let service = UsageStatsService.shared
        let allDays = service.allDays()

        allTimeTotals = UsageStatsService.sum(allDays)
        buckets = UsageSeries.buckets(for: range, days: rangeDays(from: allDays))
        rangeTotals = UsageSeries.totals(buckets)

        let activeDays = Set(allDays.filter { $0.sessions > 0 }.map(\.day))
        currentStreak = UsageStatsService.currentStreak(activeDays: activeDays, today: Date())
        longestStreak = UsageStatsService.longestStreak(activeDays: activeDays)

        isLoadingMetrics = false
    }

    /// All-time already has every row in hand, so the window is applied in memory
    /// rather than paying for a second fetch.
    private func rangeDays(from allDays: [UsageDay]) -> [UsageDay] {
        guard let window = UsageSeries.fetchRange(for: range) else { return allDays }
        return allDays.filter { window.contains($0.day) }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .semibold))
                .foregroundColor(.secondary)
            Text("No Transcriptions Yet")
                .font(.title3.weight(.semibold))
            Text("Start your first recording to unlock value insights.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer(minLength: 0)

                (Text("You have saved ")
                    .fontWeight(.bold)
                    .foregroundColor(.white.opacity(0.85))
                 +
                 Text(formattedTimeSaved)
                    .fontWeight(.black)
                    .font(.system(size: 36, design: .rounded))
                    .foregroundStyle(.white)
                 +
                 Text(" with Zerm")
                    .fontWeight(.bold)
                    .foregroundColor(.white.opacity(0.85))
                )
                .font(.system(size: 30))
                .multilineTextAlignment(.center)

                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            Text(heroSubtitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(heroGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 30, x: 0, y: 16)
    }

    /// One control above everything it scopes — the cards and both charts move together.
    private var rangePicker: some View {
        HStack {
            Picker("", selection: $range) {
                ForEach(UsageRange.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            Spacer()
        }
    }

    private var metricsSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
            MetricCard(
                icon: "mic.fill",
                title: "Sessions Recorded",
                value: UsageFormatters.number(rangeTotals.sessions),
                detail: allTimeDetail("\(UsageFormatters.number(allTimeTotals.sessions)) all time"),
                color: .purple
            )

            MetricCard(
                icon: "text.alignleft",
                title: "Words Dictated",
                value: UsageFormatters.number(rangeTotals.words),
                detail: allTimeDetail("\(UsageFormatters.number(allTimeTotals.words)) all time"),
                color: Color(nsColor: .controlAccentColor)
            )

            MetricCard(
                icon: "speedometer",
                title: "Words Per Minute",
                value: formattedRate(rangeTotals),
                detail: allTimeDetail("\(formattedRate(allTimeTotals)) all time"),
                color: .yellow
            )

            MetricCard(
                icon: "keyboard.fill",
                title: "Keystrokes Saved",
                value: UsageFormatters.number(rangeTotals.keystrokesSaved),
                detail: allTimeDetail("\(UsageFormatters.number(allTimeTotals.keystrokesSaved)) all time"),
                color: .orange
            )

            MetricCard(
                icon: "speaker.wave.2.fill",
                title: "Words Read Aloud",
                value: UsageFormatters.number(rangeTotals.readAloudWords),
                detail: allTimeDetail("\(UsageFormatters.number(allTimeTotals.readAloudWords)) all time"),
                color: .blue
            )

            MetricCard(
                icon: "flame.fill",
                title: "Current Streak",
                value: currentStreak == 1 ? "1 day" : "\(currentStreak) days",
                detail: longestStreak == 1 ? "Longest 1 day" : "Longest \(longestStreak) days",
                color: .red
            )
        }
    }

    private var footerActionsView: some View {
        CopySystemInfoButton()
    }

    // MARK: - Formatting

    /// The range number on its own is ambiguous, so every card names its window and
    /// carries the lifetime figure beside it.
    private func allTimeDetail(_ lifetime: String) -> String {
        "\(range.caption) · \(lifetime)"
    }

    private func formattedRate(_ totals: UsageTotals) -> String {
        totals.wordsPerMinute > 0 ? String(format: "%.1f", totals.wordsPerMinute) : "–"
    }

    private var formattedTimeSaved: String {
        UsageFormatters.duration(
            allTimeTotals.timeSaved,
            style: .full,
            fallback: "Time savings coming soon"
        )
    }

    private var heroSubtitle: String {
        guard allTimeTotals.sessions > 0 else {
            return "Your Zerm journey starts with your first recording."
        }

        let wordsText = UsageFormatters.number(allTimeTotals.words)
        let sessionText = allTimeTotals.sessions == 1 ? "session" : "sessions"

        return "Dictated \(wordsText) words across \(allTimeTotals.sessions) \(sessionText), all time."
    }

    private var heroGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(nsColor: .controlAccentColor),
                Color(nsColor: .controlAccentColor).opacity(0.85),
                Color(nsColor: .controlAccentColor).opacity(0.7)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct CopySystemInfoButton: View {
    @State private var isCopied: Bool = false

    var body: some View {
        Button(action: {
            copySystemInfo()
        }) {
            HStack(spacing: 8) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .rotationEffect(.degrees(isCopied ? 360 : 0))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCopied)

                Text(isCopied ? "Copied!" : "Copy System Info")
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCopied)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(.thinMaterial))
        }
        .buttonStyle(.plain)
        .scaleEffect(isCopied ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCopied)
    }

    private func copySystemInfo() {
        SystemInfoService.shared.copySystemInfoToClipboard()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isCopied = false
            }
        }
    }
}
