import SwiftUI
import LaunchAtLogin

/// Cached "launch at login" state.
///
/// `LaunchAtLogin.isEnabled` is a synchronous XPC round-trip to `servicemanagementd`
/// (`SMAppService.mainApp.status`) that costs ~300 ms. Reading it from a view's stored
/// property or body means paying that on the main thread every time the view is
/// constructed — and `MenuBarView` is constructed on *every* re-evaluation of the App
/// body, including every `recordingState` change. That was the stall between pressing
/// the dictation hotkey and the recorder actually going live. Read it off the main
/// thread once and serve the cached value from then on.
@MainActor
final class LaunchAtLoginStore: ObservableObject {
    static let shared = LaunchAtLoginStore()

    @Published private(set) var isEnabled = false
    private var hasLoaded = false

    private init() {}

    /// Loads the real status off the main thread. Safe to call repeatedly.
    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refresh()
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let value = LaunchAtLogin.isEnabled
            await MainActor.run { LaunchAtLoginStore.shared.isEnabled = value }
        }
    }

    func setEnabled(_ newValue: Bool) {
        guard newValue != isEnabled else { return }
        isEnabled = newValue                       // optimistic — the toggle stays responsive
        Task.detached(priority: .utility) {
            LaunchAtLogin.isEnabled = newValue
            let actual = LaunchAtLogin.isEnabled
            await MainActor.run { LaunchAtLoginStore.shared.isEnabled = actual }
        }
    }

    var binding: Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { self.setEnabled($0) })
    }
}

struct MenuBarView: View {
    @EnvironmentObject var engine: ZermEngine
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var hotkeyManager: HotkeyManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var enhancementService: AIEnhancementService
    @ObservedObject private var launchAtLogin = LaunchAtLoginStore.shared
    
    var body: some View {
        VStack {
            Button("Toggle Recorder") {
                recorderUIManager.handleToggleMiniRecorder()
            }

            Divider()

            Toggle("AI Enhancement", isOn: $enhancementService.isEnhancementEnabled)

            Divider()

            Button("Retry Last Transcription") {
                LastTranscriptionService.retryLastTranscription(
                    from: engine.modelContext,
                    transcriptionModelManager: transcriptionModelManager,
                    serviceRegistry: engine.serviceRegistry,
                    enhancementService: enhancementService
                )
            }

            Button("Copy Last Transcription") {
                LastTranscriptionService.copyLastTranscription(from: engine.modelContext)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            
            Button("History") {
                menuBarManager.openHistoryWindow()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            
            Button("Settings") {
                menuBarManager.openMainWindowAndNavigate(to: "Settings")
            }
            .keyboardShortcut(",", modifiers: .command)
            
            Button(menuBarManager.isMenuBarOnly ? "Show Dock Icon" : "Hide Dock Icon") {
                menuBarManager.toggleMenuBarOnly()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            
            Toggle("Launch at Login", isOn: launchAtLogin.binding)
                .onAppear { launchAtLogin.loadIfNeeded() }

            Divider()
            
            Button(updaterViewModel.updateAvailable
                   ? "Install Update\(updaterViewModel.availableVersion.map { " v\($0)" } ?? "")…"
                   : "Check for Updates") {
                if updaterViewModel.updateAvailable {
                    updaterViewModel.installPendingUpdate()
                } else {
                    updaterViewModel.checkForUpdates()
                }
            }
            .disabled(!updaterViewModel.canCheckForUpdates && !updaterViewModel.updateAvailable)
            
            Button("Help and Support") {
                EmailSupport.openSupportEmail()
            }
            
            Divider()

            Button("Quit Zerm") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}