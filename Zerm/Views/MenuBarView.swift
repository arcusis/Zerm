import SwiftUI
import LaunchAtLogin

struct MenuBarView: View {
    @EnvironmentObject var engine: ZermEngine
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var hotkeyManager: HotkeyManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var enhancementService: AIEnhancementService
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    
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
            
            Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { oldValue, newValue in
                    LaunchAtLogin.isEnabled = newValue
                }
            
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