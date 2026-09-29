import SwiftUI

/// The native macOS Settings root. The app scene and main-window destination share this root.
struct SettingsRootView: View {
    @AppStorage("selectedSettingsPane") private var selectedPane: SettingsPane = .general

    var body: some View {
        TabView(selection: $selectedPane) {
            ForEach(SettingsPane.allCases) { pane in
                paneContent(for: pane)
                    .accessibilityIdentifier(pane.paneAccessibilityIdentifier)
                    .tabItem {
                        Label(pane.tabTitle, systemImage: pane.symbol)
                            .accessibilityIdentifier(pane.accessibilityIdentifier)
                    }
                    .tag(pane)
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .accessibilityIdentifier("settings-root")
    }

    @ViewBuilder
    private func paneContent(for pane: SettingsPane) -> some View {
        switch pane {
        case .general, .shortcutsAutomation, .storageBackup, .advanced, .diagnostics:
            SettingsPaneContainer(pane: pane) {
                SettingsView(pane: pane)
            }
        case .audio:
            AudioSettingsRootPane()
        case .clipboardHistory:
            SettingsPaneContainer(pane: pane) {
                ClipboardHistorySettingsView()
            }
        case .modelsProviders:
            SettingsPaneContainer(pane: pane) {
                ModelManagementView()
            }
        case .permissionsPrivacy:
            PrivacySettingsRootPane()
                .accessibilityIdentifier("settings-pane-privacy")
        }
    }
}

private struct AudioSettingsRootPane: View {
    @State private var section: Section = .input

    private enum Section: String, CaseIterable, Identifiable {
        case input
        case behavior
        case readAloud

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .input: "Input"
            case .behavior: "Behavior"
            case .readAloud: "Read Aloud"
            }
        }
    }

    var body: some View {
        SettingsPaneContainer(pane: .audio) {
            VStack(spacing: 0) {
                Picker("Audio settings", selection: $section) {
                    ForEach(Section.allCases) { section in
                        Text(section.title)
                            .tag(section)
                            .accessibilityIdentifier("settings-audio-section-\(section.rawValue)")
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Audio settings")
                .accessibilityIdentifier("settings-audio-section-picker")
                .frame(maxWidth: 560)
                .padding()

                Divider()

                switch section {
                case .input:
                    AudioInputSettingsView()
                case .behavior:
                    SettingsView(pane: .audio)
                case .readAloud:
                    TextToSpeechSettingsView()
                        .accessibilityIdentifier("settings-audio-read-aloud")
                }
            }
        }
    }
}

private struct PrivacySettingsRootPane: View {
    var body: some View {
        SettingsPaneContainer(pane: .permissionsPrivacy) {
            PermissionsView()
        }
    }
}

private struct SettingsPaneContainer<Content: View>: View {
    let pane: SettingsPane
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title)
                    .font(.title2.weight(.semibold))
                Text(pane.description)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
