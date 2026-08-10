import OSLog
import SwiftUI

/// A task-oriented destination in Zerm's primary navigation.
///
/// Routes are values rather than display strings so navigation, notifications and future deep
/// links can share one compiler-checked vocabulary. `title` remains presentation-only.
enum AppRoute: String, Hashable, Identifiable {
    case dashboard
    case dictationHistory
    case dictationModels
    case dictationEnhancement
    case dictationVocabulary
    case meetings
    case readAloud
    case powerModes
    case permissions
    case audioInput
    case settings

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .dictationHistory: "History"
        case .dictationModels: "Models"
        case .dictationEnhancement: "Enhancement"
        case .dictationVocabulary: "Vocabulary"
        case .meetings: "Meetings"
        case .readAloud: "Read Aloud"
        case .powerModes: "Power Modes"
        case .permissions: "Permissions"
        case .audioInput: "Audio Input"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.medium"
        case .dictationHistory: "clock.arrow.circlepath"
        case .dictationModels: "waveform.badge.magnifyingglass"
        case .dictationEnhancement: "wand.and.stars"
        case .dictationVocabulary: "character.book.closed"
        case .meetings: "person.2.wave.2"
        case .readAloud: "speaker.wave.2"
        case .powerModes: "slider.horizontal.3"
        case .permissions: "hand.raised"
        case .audioInput: "mic"
        case .settings: "gearshape"
        }
    }

    /// Compatibility at the boundary for existing notification senders. New callers should send
    /// `AppRoute` in `userInfo["route"]` rather than introducing another destination string.
    init?(legacyDestination: String) {
        switch legacyDestination {
        case "Dashboard": self = .dashboard
        case "Recording", "Meetings": self = .meetings
        case "History": self = .dictationHistory
        case "Dictation Models", "Models": self = .dictationModels
        case "Enhancement": self = .dictationEnhancement
        case "Dictionary", "Vocabulary": self = .dictationVocabulary
        case "Read Aloud": self = .readAloud
        case "Power Mode", "Power Modes": self = .powerModes
        case "Permissions": self = .permissions
        case "Audio Input": self = .audioInput
        case "Settings", "Zerm Pro": self = .settings
        default: return nil
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
}

struct ContentView: View {
    @EnvironmentObject private var meetingRecordingController: MeetingRecordingController
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @AppStorage("powerModeUIFlag") private var powerModeUIFlag = false
    @AppStorage("sidebarDictationExpanded") private var isDictationExpanded = true
    @State private var selectedRoute: AppRoute? = .dashboard

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "ContentView")

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedRoute: $selectedRoute,
                isDictationExpanded: $isDictationExpanded,
                showsPowerModes: powerModeUIFlag,
                updater: updaterViewModel
            )
        } detail: {
            DetailDestination(route: selectedRoute ?? .dashboard)
                .navigationTitle((selectedRoute ?? .dashboard).title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("destination-\((selectedRoute ?? .dashboard).rawValue)")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .help("Show or hide the sidebar")
                .accessibilityIdentifier("toggle-sidebar")
            }
            ToolbarItem(placement: .primaryAction) {
                MeetingGlobalStatusButton(controller: meetingRecordingController)
            }
        }
        .onAppear {
            logger.notice("ContentView appeared")
        }
        .onDisappear {
            logger.notice("ContentView disappeared")
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDestination), perform: navigate)
    }

    private func navigate(_ notification: Notification) {
        if let route = notification.userInfo?["route"] as? AppRoute {
            selectedRoute = route
            return
        }

        guard let destination = notification.userInfo?["destination"] as? String,
              let route = AppRoute(legacyDestination: destination) else {
            return
        }

        logger.notice("Legacy navigation destination received: \(destination, privacy: .public)")
        selectedRoute = route
    }

    private func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }
}

private struct SidebarView: View {
    @Binding var selectedRoute: AppRoute?
    @Binding var isDictationExpanded: Bool

    let showsPowerModes: Bool
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        List(selection: $selectedRoute) {
            NavigationLink(value: AppRoute.dashboard) {
                SidebarLabel(route: .dashboard)
            }
            .accessibilityIdentifier("sidebar-dashboard")

            Section {
                DisclosureGroup(isExpanded: $isDictationExpanded) {
                    SidebarLink(route: .dictationHistory)
                    SidebarLink(route: .dictationModels)
                    SidebarLink(route: .dictationEnhancement)
                    SidebarLink(route: .dictationVocabulary)
                } label: {
                    Label("Dictation", systemImage: "mic.badge.plus")
                        .fontWeight(.medium)
                        .accessibilityIdentifier("dictation-navigation-group")
                }

                SidebarLink(route: .meetings)
                SidebarLink(route: .readAloud)
            } header: {
                Text("Speech")
                    .accessibilityIdentifier("sidebar-group-speech")
            }

            if showsPowerModes {
                Section {
                    SidebarLink(route: .powerModes)
                } header: {
                    Text("Automation")
                        .accessibilityIdentifier("sidebar-group-automation")
                }
            }

            Section {
                SidebarLink(route: .permissions)
                SidebarLink(route: .audioInput)
                SidebarLink(route: .settings)
            } header: {
                Text("System")
                    .accessibilityIdentifier("sidebar-group-system")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Zerm")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarUpdateBanner(updater: updater)
        }
        .accessibilityIdentifier("primary-sidebar")
    }
}

private struct SidebarLink: View {
    let route: AppRoute

    var body: some View {
        NavigationLink(value: route) {
            SidebarLabel(route: route)
        }
        .accessibilityIdentifier("sidebar-\(route.rawValue)")
    }
}

private struct SidebarLabel: View {
    let route: AppRoute

    var body: some View {
        Label(route.title, systemImage: route.icon)
            .fontWeight(.medium)
    }
}

private struct DetailDestination: View {
    @EnvironmentObject private var whisperModelManager: WhisperModelManager

    let route: AppRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case .dashboard:
            MetricsView()
        case .dictationHistory:
            InlineHistoryView()
        case .dictationModels:
            ModelManagementView()
        case .dictationEnhancement:
            EnhancementSettingsView()
        case .dictationVocabulary:
            DictionarySettingsView(whisperPrompt: whisperModelManager.whisperPrompt)
        case .meetings:
            MeetingRecordingView()
        case .readAloud:
            TextToSpeechSettingsView()
        case .powerModes:
            PowerModeView()
        case .permissions:
            PermissionsView()
        case .audioInput:
            AudioInputSettingsView()
        case .settings:
            SettingsRootView()
        }
    }
}

private struct MeetingGlobalStatusButton: View {
    @ObservedObject var controller: MeetingRecordingController
    @AppStorage("meetingSummarise") private var summariseAfterMeeting = true
    @State private var didStopSimulatedMeeting = false

    private var simulatesActiveMeeting: Bool {
        UITestLaunchConfiguration.current.isEnabled
            && UITestLaunchConfiguration.current.scenario == .activeMeeting
            && !didStopSimulatedMeeting
    }

    var body: some View {
        Group {
            switch simulatesActiveMeeting ? .capturing : controller.lifecycle.phase {
            case .capturing:
                Button(action: stopMeeting) {
                    Label("Stop Meeting", systemImage: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .help("Stop the active meeting recording")
                .accessibilityIdentifier("global-stop-meeting")
            case .stopping, .processing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Processing Meeting")
                }
                .accessibilityElement(children: .combine)
            default:
                EmptyView()
            }
        }
    }

    private func stopMeeting() {
        if simulatesActiveMeeting {
            didStopSimulatedMeeting = true
            return
        }
        Task {
            await controller.stopAndSummarise(
                ifRequested: summariseAfterMeeting && controller.isLocalSummaryAvailable == true
            )
        }
    }
}
