import SwiftUI
import Cocoa
import KeyboardShortcuts
import AVFoundation

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var hotkeyManager: HotkeyManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @StateObject private var deviceManager = AudioDeviceManager.shared
    @ObservedObject private var soundManager = SoundManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginStore.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @AppStorage("enableAnnouncements") private var enableAnnouncements = true
    @AppStorage("restoreClipboardAfterPaste") private var restoreClipboardAfterPaste = false
    @AppStorage("clipboardRestoreDelay") private var clipboardRestoreDelay = 2.0
    @AppStorage("useAppleScriptPaste") private var useAppleScriptPaste = false
    @State private var showResetOnboardingAlert = false
    @State private var currentShortcut = KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder)
    @State private var isCustomCancelEnabled = KeyboardShortcuts.getShortcut(for: .cancelRecorder) != nil

    // Expansion states - all collapsed by default
    @State private var isCustomCancelExpanded = false
    @State private var isMiddleClickExpanded = false
    @State private var isSoundFeedbackExpanded = false
    @State private var isMuteSystemExpanded = false
    @State private var isRestoreClipboardExpanded = false

    var body: some View {
        Form {
            // MARK: - Shortcuts
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Spacer()
                        if hotkeyManager.selectedHotkey1 != .none {
                            hotkeyModePicker(binding: $hotkeyManager.hotkeyMode1)
                        }
                        hotkeyPicker(binding: $hotkeyManager.selectedHotkey1)
                        if hotkeyManager.selectedHotkey1 == .custom {
                            KeyboardShortcuts.Recorder(for: .toggleMiniRecorder)
                                .controlSize(.small)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Shortcut 1")
                        InfoTip(shortcutHelp, doc: .shortcuts)
                    }
                }

                if hotkeyManager.selectedHotkey2 != .none {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Spacer()
                            hotkeyModePicker(binding: $hotkeyManager.hotkeyMode2)
                            hotkeyPicker(binding: $hotkeyManager.selectedHotkey2)
                            if hotkeyManager.selectedHotkey2 == .custom {
                                KeyboardShortcuts.Recorder(for: .toggleMiniRecorder2)
                                    .controlSize(.small)
                            }
                            Button {
                                withAnimation { hotkeyManager.selectedHotkey2 = .none }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Shortcut 2")
                            InfoTip(
                                "A second, independent key for the same recorder, with its own mode. Handy when you want a hold-to-talk key for quick asides and a toggle key for long dictation. The minus button removes it.",
                                doc: .shortcuts
                            )
                        }
                    }
                }

                if hotkeyManager.selectedHotkey1 != .none && hotkeyManager.selectedHotkey2 == .none {
                    HStack(spacing: 4) {
                        Button("Add Second Shortcut") {
                            withAnimation { hotkeyManager.selectedHotkey2 = .rightOption }
                        }
                        InfoTip(
                            "Adds a second key that starts the recorder, with its own Toggle / Push to Talk / Hybrid mode. Both shortcuts stay active.",
                            doc: .shortcuts
                        )
                    }
                }
            } header: {
                Text("Shortcuts")
            }

            // MARK: - Additional Shortcuts
            Section("Additional Shortcuts") {
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .pasteLastTranscription)
                        .controlSize(.small)
                } label: {
                    HStack(spacing: 4) {
                        Text("Paste Last Transcription (Original)")
                        InfoTip(
                            "Pastes the raw transcript of your most recent dictation again, exactly as the model heard it, with no AI enhancement. Useful when a paste landed in the wrong window, or when the enhanced version changed something you wanted kept.",
                            doc: .shortcuts
                        )
                    }
                }

                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .pasteLastEnhancement)
                        .controlSize(.small)
                } label: {
                    HStack(spacing: 4) {
                        Text("Paste Last Transcription (Enhanced)")
                        InfoTip(
                            "Pastes the AI-enhanced version of your most recent dictation again. Nothing is re-sent to the provider — this replays the result that was already produced.",
                            doc: .shortcuts
                        )
                    }
                }

                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .retryLastTranscription)
                        .controlSize(.small)
                } label: {
                    HStack(spacing: 4) {
                        Text("Retry Last Transcription")
                        InfoTip(
                            "Runs the last recording through transcription again, using whatever model and language are selected now. Use it after switching to a more accurate model, or when a transcript came back garbled — the original audio is reused, so you don't have to speak again.",
                            doc: .shortcuts
                        )
                    }
                }

                // Custom Cancel - hierarchical
                ExpandableSettingsRow(
                    isExpanded: $isCustomCancelExpanded,
                    isEnabled: $isCustomCancelEnabled,
                    label: "Custom Cancel Shortcut",
                    infoMessage: "Escape always discards the recording while the recorder is showing. Turn this on to add a second key that does the same, for when your hand is nowhere near Escape.",
                    infoURL: Links.docString(.shortcuts)
                ) {
                    LabeledContent("Shortcut") {
                        KeyboardShortcuts.Recorder(for: .cancelRecorder)
                            .controlSize(.small)
                    }
                }
                .onChange(of: isCustomCancelEnabled) { _, newValue in
                    if !newValue {
                        KeyboardShortcuts.setShortcut(nil, for: .cancelRecorder)
                        isCustomCancelExpanded = false
                    }
                }

                // Middle-Click
                ExpandableSettingsRow(
                    isExpanded: $isMiddleClickExpanded,
                    isEnabled: $hotkeyManager.isMiddleClickToggleEnabled,
                    label: "Middle-Click Recording",
                    infoMessage: "Starts and stops recording with the middle mouse button — the scroll wheel click — so you can dictate without reaching for the keyboard. Leave it off if you use middle-click to open links in tabs.",
                    infoURL: Links.docString(.shortcuts)
                ) {
                    LabeledContent {
                        HStack {
                            TextField("", value: $hotkeyManager.middleClickActivationDelay, formatter: {
                                let formatter = NumberFormatter()
                                formatter.minimum = 0
                                return formatter
                            }())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("ms")
                                .foregroundColor(.secondary)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Activation Delay")
                            InfoTip("How long the middle button must be held before recording starts. Raise it if ordinary middle-clicks in your browser keep opening the recorder by accident; set it to 0 for an instant response.")
                        }
                    }
                }
            }

            // MARK: - Paste Options
            Section("Paste Options") {
                ExpandableSettingsRow(
                    isExpanded: $isRestoreClipboardExpanded,
                    isEnabled: $restoreClipboardAfterPaste,
                    label: "Restore Clipboard After Paste",
                    infoMessage: "Pasting works by putting the transcript on the clipboard, which overwrites whatever you had copied. Turn this on to put your previous clipboard contents back once the paste has landed."
                ) {
                    Picker(selection: $clipboardRestoreDelay) {
                        Text("250ms").tag(0.25)
                        Text("500ms").tag(0.5)
                        Text("1s").tag(1.0)
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                        Text("4s").tag(4.0)
                        Text("5s").tag(5.0)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Restore Delay")
                            InfoTip("How long to wait before putting your old clipboard contents back. Slower apps read the clipboard a moment after the paste; if you end up with the wrong text, increase this.")
                        }
                    }
                }

                Toggle(isOn: $useAppleScriptPaste) {
                    HStack(spacing: 4) {
                        Text("Use AppleScript Paste")
                        InfoTip("Enable this if pasting doesn't work with your keyboard layout (e.g. Neo2). Uses AppleScript instead of simulated key events.")
                    }
                }
            }

            // MARK: - Recording Feedback
            Section("Recording Feedback") {
                // Sound Feedback
                ExpandableSettingsRow(
                    isExpanded: $isSoundFeedbackExpanded,
                    isEnabled: $soundManager.isEnabled,
                    label: "Sound Feedback",
                    infoMessage: "Plays a short sound when recording starts and another when it stops, so you know the recorder is listening without looking at it. Expand to choose your own sounds."
                ) {
                    CustomSoundSettingsView()
                }

                // Mute System Audio
                ExpandableSettingsRow(
                    isExpanded: $isMuteSystemExpanded,
                    isEnabled: $mediaController.isSystemMuteEnabled,
                    label: "Mute Audio While Recording",
                    infoMessage: "Silences your Mac's output for the length of the recording, then restores the previous volume. Stops music or a video call leaking into the microphone and being transcribed as speech."
                ) {
                    Picker(selection: $mediaController.audioResumptionDelay) {
                        Text("0s").tag(0.0)
                        Text("1s").tag(1.0)
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                        Text("4s").tag(4.0)
                        Text("5s").tag(5.0)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Resume Delay")
                            InfoTip("How long after recording stops before the volume comes back. A second or two keeps audio from returning over the top of the paste.")
                        }
                    }
                }

                MicTestView()
            }

            // MARK: - Power Mode
            PowerModeSection()

            // MARK: - Interface
            Section("Interface") {
                Picker(selection: $recorderUIManager.recorderType) {
                    Text("Notch").tag("notch")
                    Text("Mini").tag("mini")
                } label: {
                    HStack(spacing: 4) {
                        Text("Recorder Style")
                        InfoTip("Where the recorder appears while you dictate. Notch sits in the menu bar area at the top of the screen, around the camera housing on Macs that have one. Mini is a small floating pill you can drag anywhere.")
                    }
                }
                .pickerStyle(.segmented)

            }

            // MARK: - Experimental
            ExperimentalSection()

            // MARK: - General
            Section("General") {
                Toggle(isOn: $menuBarManager.isMenuBarOnly) {
                    HStack(spacing: 4) {
                        Text("Hide Dock Icon")
                        InfoTip("Removes Zerm from the Dock and the app switcher, leaving only the menu bar icon. Everything keeps working; open this window again from the menu bar.")
                    }
                }

                // Not `LaunchAtLogin.Toggle` — it re-reads SMAppService.status (a blocking
                // XPC call) on every body evaluation. See `LaunchAtLoginStore`.
                Toggle(isOn: launchAtLogin.binding) {
                    HStack(spacing: 4) {
                        Text("Launch at Login")
                        InfoTip("Starts Zerm automatically when you log in, so your dictation shortcut works without opening the app first.")
                    }
                }
                .onAppear { launchAtLogin.loadIfNeeded() }

                Toggle(isOn: $autoUpdateCheck) {
                    HStack(spacing: 4) {
                        Text("Auto-check Updates")
                        InfoTip("Looks for new versions in the background and tells you when one is ready. Nothing installs on its own — you still choose when to update.")
                    }
                }
                .onChange(of: autoUpdateCheck) { _, newValue in
                    updaterViewModel.toggleAutoUpdates(newValue)
                }

                Toggle(isOn: $enableAnnouncements) {
                    HStack(spacing: 4) {
                        Text("Show Announcements")
                        InfoTip(
                            "Shows occasional in-app notes about new features and known issues. Turn it off for a completely quiet app.",
                            doc: .announcements
                        )
                    }
                }
                .onChange(of: enableAnnouncements) { _, newValue in
                    if newValue {
                        AnnouncementsService.shared.start()
                    } else {
                        AnnouncementsService.shared.stop()
                    }
                }

                HStack {
                    Button(updaterViewModel.updateAvailable ? "Install Update…" : "Check for Updates") {
                        if updaterViewModel.updateAvailable {
                            updaterViewModel.installPendingUpdate()
                        } else {
                            updaterViewModel.checkForUpdates()
                        }
                    }
                    .disabled(!updaterViewModel.canCheckForUpdates && !updaterViewModel.updateAvailable)

                    if updaterViewModel.updateAvailable, let version = updaterViewModel.availableVersion {
                        Text("v\(version) available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if updaterViewModel.isChecking {
                        ProgressView().controlSize(.small)
                    }

                    Button("Reset Onboarding") {
                        showResetOnboardingAlert = true
                    }
                    InfoTip("Shows the welcome and setup screens again the next time you launch Zerm. Your settings, prompts and history are left alone.")
                }

                if let error = updaterViewModel.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // MARK: - Privacy
            Section {
                AudioCleanupSettingsView()
            } header: {
                Text("Privacy")
            } footer: {
                Text("Control how Zerm handles your transcription data and audio recordings.")
            }

            // MARK: - Backup
            Section {
                LabeledContent {
                    Button("Export") {
                        ImportExportService.shared.exportSettings(
                            enhancementService: enhancementService,
                            whisperPrompt: WhisperPrompt(),
                            hotkeyManager: hotkeyManager,
                            menuBarManager: menuBarManager,
                            mediaController: mediaController,
                            playbackController: playbackController,
                            soundManager: soundManager,
                            recorderUIManager: recorderUIManager,
                            modelContext: modelContext
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Export Settings")
                        InfoTip("Writes a single file containing your settings, prompts, Power Modes, dictionary and custom models. Keep it as a backup or use it to set up Zerm the same way on another Mac. API keys are not included.")
                    }
                }

                LabeledContent {
                    Button("Import") {
                        ImportExportService.shared.importSettings(
                            enhancementService: enhancementService,
                            whisperPrompt: WhisperPrompt(),
                            hotkeyManager: hotkeyManager,
                            menuBarManager: menuBarManager,
                            mediaController: mediaController,
                            playbackController: playbackController,
                            soundManager: soundManager,
                            recorderUIManager: recorderUIManager,
                            modelContext: modelContext,
                            transcriptionModelManager: transcriptionModelManager
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Import Settings")
                        InfoTip("Loads a previously exported file. This overwrites your current settings, prompts, Power Modes and dictionary, so export first if you want a way back.")
                    }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Export or import all your settings, prompts, power modes, dictionary, and custom models.")
            }

            // MARK: - Diagnostics
            Section("Diagnostics") {
                DiagnosticsSettingsView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.controlBackgroundColor))
        .alert("Reset Onboarding", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                DispatchQueue.main.async {
                    hasCompletedOnboarding = false
                }
            }
        } message: {
            Text("You'll see the introduction screens again the next time you launch the app.")
        }
    }

    /// Covers both pickers on a shortcut row — the key itself and the mode beside it.
    private let shortcutHelp = """
    The key that opens the recorder and starts dictation. Toggle starts on one press and stops \
    on the next; Push to Talk records only while the key is held; Hybrid does both — a quick tap \
    toggles, holding for longer than half a second records until you let go. Choose Custom to \
    record any key combination you like.
    """

    @ViewBuilder
    private func hotkeyPicker(binding: Binding<HotkeyManager.HotkeyOption>) -> some View {
        Picker("", selection: binding) {
            ForEach(HotkeyManager.HotkeyOption.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func hotkeyModePicker(binding: Binding<HotkeyManager.HotkeyMode>) -> some View {
        Picker("", selection: binding) {
            ForEach(HotkeyManager.HotkeyMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Expandable Settings Row (entire row clickable)

struct ExpandableSettingsRow<Content: View>: View {
    @Binding var isExpanded: Bool
    @Binding var isEnabled: Bool
    let label: String
    var infoMessage: String? = nil
    var infoURL: String? = nil
    @ViewBuilder let content: () -> Content

    @State private var isHandlingToggleChange = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - entire area is tappable
            HStack {
                Toggle(isOn: $isEnabled) {
                    HStack(spacing: 4) {
                        Text(label)
                        if let message = infoMessage {
                            if let url = infoURL {
                                InfoTip(message, learnMoreURL: url)
                            } else {
                                InfoTip(message)
                            }
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isEnabled && isExpanded ? 90 : 0))
                    .opacity(isEnabled ? 1 : 0.4)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isHandlingToggleChange else { return }
                if isEnabled {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded content with proper spacing
            if isEnabled && isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.top, 12)
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .onChange(of: isEnabled) { _, newValue in
            isHandlingToggleChange = true
            if newValue {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
            } else {
                isExpanded = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isHandlingToggleChange = false
            }
        }
    }
}

// MARK: - Power Mode Section

struct PowerModeSection: View {
    @ObservedObject private var powerModeManager = PowerModeManager.shared
    @AppStorage("powerModeUIFlag") private var powerModeUIFlag = false
    @AppStorage("powerModePersistConfig") private var powerModePersistSettings = false
    @State private var showDisableAlert = false
    @State private var isExpanded = false

    var body: some View {
        Section {
            ExpandableSettingsRow(
                isExpanded: $isExpanded,
                isEnabled: toggleBinding,
                label: "Power Mode",
                infoMessage: "Apply custom settings based on active app or website.",
                infoURL: Links.docString(.powerMode)
            ) {
                Toggle(isOn: $powerModePersistSettings) {
                    HStack(spacing: 4) {
                        Text("Persist Configured Preferences")
                        InfoTip("When enabled, Power Mode preferences stay active after you stop recording instead of reverting to your original preferences. They will only change when a different Power Mode activates.")
                    }
                }
            }
        } header: {
            Text("Power Mode")
        }
        .alert("Power Mode Still Active", isPresented: $showDisableAlert) {
            Button("Got it", role: .cancel) { }
        } message: {
            Text("Disable or remove your Power Modes first.")
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { powerModeUIFlag },
            set: { newValue in
                if newValue {
                    powerModeUIFlag = true
                } else if powerModeManager.configurations.allSatisfy({ !$0.isEnabled }) {
                    powerModeUIFlag = false
                } else {
                    showDisableAlert = true
                }
            }
        )
    }
}

// MARK: - Experimental Section

struct ExperimentalSection: View {
    @ObservedObject private var playbackController = PlaybackController.shared
    @ObservedObject private var mediaController = MediaController.shared
    @AppStorage("UseVoiceProcessingIO") private var useVoiceProcessingIO = false
    @State private var isPauseMediaExpanded = false

    var body: some View {
        Section {
            ExpandableSettingsRow(
                isExpanded: $isPauseMediaExpanded,
                isEnabled: $playbackController.isPauseMediaEnabled,
                label: "Pause Media While Recording",
                infoMessage: "Pauses playing media when recording starts and resumes when done."
            ) {
                Picker(selection: $mediaController.audioResumptionDelay) {
                    Text("0s").tag(0.0)
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                    Text("3s").tag(3.0)
                    Text("4s").tag(4.0)
                    Text("5s").tag(5.0)
                } label: {
                    HStack(spacing: 4) {
                        Text("Resume Delay")
                        InfoTip("How long after recording stops before playback picks up again. This is the same delay used by Mute Audio While Recording.")
                    }
                }
            }

            Toggle(isOn: $useVoiceProcessingIO) {
                HStack(spacing: 4) {
                    Text("Echo Cancel / AGC")
                    InfoTip("Uses VoiceProcessingIO for acoustic echo cancellation and automatic gain control. Helpful in noisy rooms or when speakers are on. Restart recording after changing.")
                }
            }
        } header: {
            Text("Experimental")
        }
    }
}

// MARK: - Text Extension

extension Text {
    func settingsDescription() -> some View {
        self
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
