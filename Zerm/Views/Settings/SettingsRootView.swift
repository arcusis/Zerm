import SwiftUI

/// The native macOS Settings root. The app scene can present this view from `Settings { ... }`;
/// the main-window Settings destination uses the same root so both entry points stay identical.
struct SettingsRootView: View {
    @AppStorage("selectedSettingsPane") private var selectedPane: SettingsPane = .general

    var body: some View {
        TabView(selection: $selectedPane) {
            SettingsPaneContainer(
                title: "General",
                description: "App behavior, appearance and updates."
            ) {
                SettingsView(pane: .general)
            }
            .accessibilityIdentifier("settings-pane-general")
            .tabItem {
                Label("General", systemImage: "gearshape")
                    .accessibilityIdentifier("settings-tab-general")
            }
            .tag(SettingsPane.general)

            SettingsPaneContainer(
                title: "Shortcuts & Automation",
                description: "Dictation shortcuts, paste behavior and Power Modes."
            ) {
                SettingsView(pane: .shortcutsAutomation)
            }
            .accessibilityIdentifier("settings-pane-shortcuts")
            .tabItem {
                Label("Shortcuts", systemImage: "command")
                    .accessibilityIdentifier("settings-tab-shortcuts")
            }
            .tag(SettingsPane.shortcutsAutomation)

            AudioSettingsRootPane()
                .accessibilityIdentifier("settings-pane-audio")
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                        .accessibilityIdentifier("settings-tab-audio")
                }
                .tag(SettingsPane.audio)

            SettingsPaneContainer(
                title: "Models & Providers",
                description: "Choose local or cloud models and configure their languages."
            ) {
                ModelManagementView()
            }
            .accessibilityIdentifier("settings-pane-models")
            .tabItem {
                Label("Models", systemImage: "cpu")
                    .accessibilityIdentifier("settings-tab-models")
            }
            .tag(SettingsPane.modelsProviders)

            PrivacySettingsRootPane()
                .accessibilityIdentifier("settings-pane-privacy")
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                        .accessibilityIdentifier("settings-tab-privacy")
                }
                .tag(SettingsPane.permissionsPrivacy)

            SettingsPaneContainer(
                title: "Storage & Backup",
                description: "Manage audio retention and portable settings backups."
            ) {
                SettingsView(pane: .storageBackup)
            }
            .accessibilityIdentifier("settings-pane-storage")
            .tabItem {
                Label("Storage", systemImage: "externaldrive")
                    .accessibilityIdentifier("settings-tab-storage")
            }
            .tag(SettingsPane.storageBackup)

            SettingsPaneContainer(
                title: "Advanced & Diagnostics",
                description: "Experimental audio behavior and troubleshooting information."
            ) {
                SettingsView(pane: .advancedDiagnostics)
            }
            .accessibilityIdentifier("settings-pane-advanced")
            .tabItem {
                Label("Advanced", systemImage: "stethoscope")
                    .accessibilityIdentifier("settings-tab-advanced")
            }
            .tag(SettingsPane.advancedDiagnostics)
        }
        .frame(minWidth: 760, minHeight: 600)
        .accessibilityIdentifier("settings-root")
    }
}

private struct AudioSettingsRootPane: View {
    @EnvironmentObject private var meetingRecordingController: MeetingRecordingController
    @State private var section: Section = .input

    private enum Section: String, CaseIterable, Identifiable {
        case input
        case behavior
        case meetings
        case readAloud

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .input: "Input"
            case .behavior: "Behavior"
            case .meetings: "Meetings"
            case .readAloud: "Read Aloud"
            }
        }
    }

    var body: some View {
        SettingsPaneContainer(
            title: "Audio",
            description: "Choose microphones and control recording feedback."
        ) {
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
                case .meetings:
                    MeetingSettingsForm(isRecording: meetingRecordingController.isRecording)
                        .accessibilityIdentifier("settings-audio-meetings")
                case .readAloud:
                    VStack(spacing: 0) {
                        ReadAloudMeetingSafetyNotice()
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                        TextToSpeechSettingsView()
                    }
                    .accessibilityIdentifier("settings-audio-read-aloud")
                }
            }
        }
    }
}

private struct ReadAloudMeetingSafetyNotice: View {
    var body: some View {
        GroupBox {
            Label(
                "During a meeting, Read Aloud works with wired headphones, Bluetooth or AirPods headsets, and USB headsets. It is blocked on speakers to prevent feedback. If headphones disconnect, Read Aloud stops and Zerm notifies you; recording and Dictation continue.",
                systemImage: "headphones"
            )
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Meeting Safety")
                .font(.headline)
        }
    }
}

private struct PrivacySettingsRootPane: View {
    var body: some View {
        SettingsPaneContainer(
            title: "Permissions & Privacy",
            description: "Review the system access Zerm needs and the privacy impact of each permission."
        ) {
            PermissionsView()
        }
    }
}

private struct SettingsPaneContainer<Content: View>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(description)
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
