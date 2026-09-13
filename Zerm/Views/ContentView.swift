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
    case dictationVocabulary
    case readAloudSpeak
    case readAloudHistory
    case readAloudModels
    case enhancement
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
        case .dictationVocabulary: "Vocabulary"
        case .readAloudSpeak: "Speak"
        case .readAloudHistory: "History"
        case .readAloudModels: "Models & Voices"
        case .enhancement: "Enhancement"
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
        case .dictationVocabulary: "character.book.closed"
        case .readAloudSpeak: "speaker.wave.2"
        case .readAloudHistory: "clock.arrow.circlepath"
        case .readAloudModels: "person.wave.2"
        case .enhancement: "wand.and.stars"
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
        case "History": self = .dictationHistory
        case "Dictation Models", "Models": self = .dictationModels
        case "Enhancement": self = .enhancement
        case "Dictionary", "Vocabulary": self = .dictationVocabulary
        case "Read Aloud", "Read Aloud Speak": self = .readAloudSpeak
        case "Read Aloud History": self = .readAloudHistory
        case "Read Aloud Models": self = .readAloudModels
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
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @AppStorage("powerModeUIFlag") private var powerModeUIFlag = false
    @AppStorage("sidebarDictationExpanded") private var isDictationExpanded = true
    @AppStorage("sidebarReadAloudExpanded") private var isReadAloudExpanded = true
    @State private var selectedRoute: AppRoute? = .dashboard

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "ContentView")

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedRoute: $selectedRoute,
                isDictationExpanded: $isDictationExpanded,
                isReadAloudExpanded: $isReadAloudExpanded,
                showsPowerModes: powerModeUIFlag,
                updater: updaterViewModel
            )
        } detail: {
            DetailDestination(route: selectedRoute ?? .dashboard)
                .id(selectedRoute ?? .dashboard)
                .navigationTitle((selectedRoute ?? .dashboard).title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("destination-\((selectedRoute ?? .dashboard).rawValue)")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
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
            navigate(to: route)
            return
        }

        guard let destination = notification.userInfo?["destination"] as? String,
              let route = AppRoute(legacyDestination: destination) else {
            return
        }

        logger.notice("Legacy navigation destination received: \(destination, privacy: .public)")
        navigate(to: route)
    }

    private func navigate(to route: AppRoute) {
        if route == .settings {
            openSettings()
        } else {
            selectedRoute = route
        }
    }
}

private struct SidebarView: View {
    @Binding var selectedRoute: AppRoute?
    @Binding var isDictationExpanded: Bool
    @Binding var isReadAloudExpanded: Bool

    let showsPowerModes: Bool
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedRoute) {
                NavigationLink(value: AppRoute.dashboard) {
                    SidebarLabel(route: .dashboard, prominence: .primary)
                }
                .accessibilityIdentifier("sidebar-dashboard")

                Section {
                    DisclosureGroup(isExpanded: $isDictationExpanded) {
                        SidebarLink(route: .dictationHistory, prominence: .secondary)
                        SidebarLink(route: .dictationModels, prominence: .secondary)
                        SidebarLink(route: .dictationVocabulary, prominence: .secondary)
                    } label: {
                        Label("Dictation", systemImage: "mic.badge.plus")
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("dictation-navigation-group")
                    }

                    DisclosureGroup(isExpanded: $isReadAloudExpanded) {
                        SidebarLink(route: .readAloudSpeak, prominence: .secondary)
                        SidebarLink(route: .readAloudHistory, prominence: .secondary)
                        SidebarLink(route: .readAloudModels, prominence: .secondary)
                    } label: {
                        Label("Read Aloud", systemImage: "speaker.wave.2")
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("read-aloud-navigation-group")
                    }

                    SidebarLink(route: .enhancement, prominence: .primary)
                } header: {
                    SidebarSectionHeader("Speech", identifier: "sidebar-group-speech")
                }

                if showsPowerModes {
                    Section {
                        SidebarLink(route: .powerModes, prominence: .primary)
                    } header: {
                        SidebarSectionHeader("Automation", identifier: "sidebar-group-automation")
                    }
                }

                Section {
                    SidebarLink(route: .permissions, prominence: .primary)
                    SidebarLink(route: .audioInput, prominence: .primary)
                } header: {
                    SidebarSectionHeader("System", identifier: "sidebar-group-system")
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("primary-sidebar")

            Divider()
            SettingsLink {
                SidebarLabel(route: .settings, prominence: .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityIdentifier("sidebar-settings")

            Divider()
            SidebarUpdateBanner(updater: updater)
        }
        .navigationTitle("Zerm")
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    }
}

private struct SidebarLink: View {
    let route: AppRoute
    let prominence: SidebarLabel.Prominence

    var body: some View {
        NavigationLink(value: route) {
            SidebarLabel(route: route, prominence: prominence)
        }
        .accessibilityIdentifier("sidebar-\(route.rawValue)")
    }
}

private struct SidebarLabel: View {
    enum Prominence {
        case primary
        case secondary
    }

    let route: AppRoute
    let prominence: Prominence

    var body: some View {
        Label(route.title, systemImage: route.icon)
            .fontWeight(prominence == .primary ? .semibold : .regular)
            .foregroundStyle(.primary)
    }
}

private struct SidebarSectionHeader: View {
    let title: LocalizedStringKey
    let identifier: String

    init(_ title: LocalizedStringKey, identifier: String) {
        self.title = title
        self.identifier = identifier
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.primary.opacity(0.72))
            .accessibilityIdentifier(identifier)
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
        case .dictationVocabulary:
            DictionarySettingsView(whisperPrompt: whisperModelManager.whisperPrompt)
        case .readAloudSpeak:
            ReadAloudSpeakView()
        case .readAloudHistory:
            ReadAloudHistoryView()
        case .readAloudModels:
            TextToSpeechSettingsView()
        case .enhancement:
            EnhancementSettingsView()
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
