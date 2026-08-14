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
    @EnvironmentObject var meetingRecordingController: MeetingRecordingController
    @AppStorage("meetingSummarise") private var summariseAfterMeeting = true
    @ObservedObject private var launchAtLogin = LaunchAtLoginStore.shared
    
    var body: some View {
        VStack {
            if meetingRecordingController.lifecycle.phase == .capturing {
                Button(action: stopMeetingRecording) {
                    Label(
                        "Stop Meeting — \(MeetingRecordingView.clock(meetingRecordingController.session.elapsed))",
                        systemImage: "stop.circle.fill"
                    )
                }
                .accessibilityIdentifier("menu-stop-meeting")

                Button("Open Meetings") {
                    menuBarManager.openMainWindowAndNavigate(to: "Meetings")
                }

                Divider()
            } else if meetingRecordingController.lifecycle.phase == .stopping
                        || meetingRecordingController.lifecycle.phase == .processing {
                Label("Processing Meeting", systemImage: "hourglass")
                Divider()
            }

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
            
            Button(menuBarManager.isMenuBarOnly
                   ? String(localized: "Show Dock Icon")
                   : String(localized: "Hide Dock Icon")) {
                menuBarManager.toggleMenuBarOnly()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            
            Toggle("Launch at Login", isOn: launchAtLogin.binding)
                .onAppear { launchAtLogin.loadIfNeeded() }

            Divider()
            
            Button(updateButtonTitle) {
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

    private func stopMeetingRecording() {
        Task {
            await meetingRecordingController.stopAndSummarise(
                ifRequested: summariseAfterMeeting
                    && meetingRecordingController.isLocalSummaryAvailable == true
            )
        }
    }

    private var updateButtonTitle: String {
        guard updaterViewModel.updateAvailable else {
            return String(localized: "Check for Updates")
        }
        guard let version = updaterViewModel.availableVersion else {
            return String(localized: "Install Update…")
        }
        return String.localizedStringWithFormat(
            String(localized: "Install Update %@…"),
            "v\(version)"
        )
    }
}
