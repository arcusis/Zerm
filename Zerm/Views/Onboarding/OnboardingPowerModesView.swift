import SwiftUI
import AppKit

/// Onboarding step that creates Power Modes from templates, bound only to apps on this Mac.
struct OnboardingPowerModesView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var scale: CGFloat = 0.8
    @State private var opacity: CGFloat = 0
    @State private var cardsVisible = false
    @State private var showTutorial = false
    @State private var choices: [TemplateChoice] = []

    /// One template with the installed apps it would bind, and which of them the user kept.
    private struct TemplateChoice: Identifiable {
        let template: PowerModeTemplate
        let apps: [PowerModeTemplate.SuggestedApp]
        var selectedApps: Set<String>
        var isIncluded: Bool

        var id: String { template.id }
    }

    var body: some View {
        ZStack {
            if showTutorial {
                OnboardingTutorialView(hasCompletedOnboarding: $hasCompletedOnboarding)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                GeometryReader { geometry in
                    OnboardingBackgroundView()

                    VStack(spacing: 32) {
                        header
                            .scaleEffect(scale)
                            .opacity(opacity)

                        VStack(spacing: 14) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                                if cardsVisible {
                                    templateCard(choice)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                        .animation(
                                            .spring(response: 0.5, dampingFraction: 0.8).delay(Double(index) * 0.08),
                                            value: cardsVisible
                                        )
                                }
                            }
                        }
                        .frame(width: min(geometry.size.width * 0.7, 560))

                        VStack(spacing: 16) {
                            Button(action: createAndContinue) {
                                Text("Continue")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(width: 200, height: 50)
                                    .background(Color.accentColor)
                                    .cornerRadius(25)
                            }
                            .buttonStyle(ScaleButtonStyle())

                            SkipButton(text: "Skip for now") {
                                withAnimation { showTutorial = true }
                            }
                        }
                        .opacity(opacity)
                    }
                    .padding()
                    .frame(width: min(geometry.size.width * 0.85, 680))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .onAppear {
            loadChoices()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                scale = 1
                opacity = 1
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15)) {
                cardsVisible = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 90, height: 90)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
            }

            Text("Power Modes")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Zerm adapts to the app you are dictating into. Pick the modes you want; you can change them anytime on the Power Mode page.")
                .font(.body)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func templateCard(_ choice: TemplateChoice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: choice.template.emoji)
                    .font(.system(size: 22))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: choice.template.name)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(verbatim: choice.template.summary)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: choice.isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(choice.isIncluded ? .accentColor : .white.opacity(0.3))
            }

            if choice.apps.isEmpty {
                Text("None of the suggested apps are installed. You can add apps later on the Power Mode page.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.45))
            } else {
                FlowRow(apps: choice.apps, selected: choice.selectedApps) { bundleIdentifier in
                    toggleApp(bundleIdentifier, in: choice.id)
                }
                .disabled(!choice.isIncluded)
                .opacity(choice.isIncluded ? 1 : 0.4)
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.3))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(choice.isIncluded ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { toggleTemplate(choice.id) }
    }

    private func loadChoices() {
        guard choices.isEmpty else { return }
        choices = PowerModeTemplate.all.map { template in
            let apps = template.installedApps()
            return TemplateChoice(
                template: template,
                apps: apps,
                selectedApps: Set(apps.map(\.bundleIdentifier)),
                isIncluded: !apps.isEmpty
            )
        }
    }

    private func toggleTemplate(_ id: String) {
        guard let index = choices.firstIndex(where: { $0.id == id }), !choices[index].apps.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            choices[index].isIncluded.toggle()
        }
    }

    private func toggleApp(_ bundleIdentifier: String, in id: String) {
        guard let index = choices.firstIndex(where: { $0.id == id }) else { return }
        if choices[index].selectedApps.contains(bundleIdentifier) {
            choices[index].selectedApps.remove(bundleIdentifier)
        } else {
            choices[index].selectedApps.insert(bundleIdentifier)
        }
    }

    private func createAndContinue() {
        for choice in choices where choice.isIncluded {
            let apps = choice.apps.filter { choice.selectedApps.contains($0.bundleIdentifier) }
            guard !apps.isEmpty else { continue }
            PowerModeManager.shared.addConfiguration(from: choice.template, apps: apps)
        }
        withAnimation { showTutorial = true }
    }
}

/// Wrapping row of app chips, each toggling whether the app is bound.
private struct FlowRow: View {
    let apps: [PowerModeTemplate.SuggestedApp]
    let selected: Set<String>
    let toggle: (String) -> Void

    var body: some View {
        WrappingLayout(spacing: 6) {
            ForEach(apps, id: \.bundleIdentifier) { app in
                let isSelected = selected.contains(app.bundleIdentifier)
                Button { toggle(app.bundleIdentifier) } label: {
                    HStack(spacing: 5) {
                        Image(nsImage: AppIconCache.icon(for: app.bundleIdentifier))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(verbatim: app.name)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundColor(isSelected ? .white : .white.opacity(0.5))
                    .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays subviews out left to right, wrapping to a new line when the width runs out.
private struct WrappingLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// App icons by bundle identifier, resolved once per app.
@MainActor
private enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleIdentifier: String) -> NSImage {
        if let icon = icons[bundleIdentifier] { return icon }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        icons[bundleIdentifier] = icon
        return icon
    }
}
