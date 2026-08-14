import SwiftUI
import Cocoa
import KeyboardShortcuts
import AVFoundation

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case shortcutsAutomation
    case audio
    case modelsProviders
    case permissionsPrivacy
    case storageBackup
    case advancedDiagnostics

    var id: Self { self }
}

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
    @ObservedObject private var audioOutputRouteMonitor = AudioOutputRouteMonitor.shared
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

    private let pane: SettingsPane?

    init(pane: SettingsPane? = nil) {
        self.pane = pane
    }

    var body: some View {
        Form {
            if pane == nil || pane == .shortcutsAutomation {
            // MARK: - Shortcuts
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Spacer()
                        if hotkeyManager.selectedHotkey1 != .none {
                            hotkeyModePicker(
                                binding: $hotkeyManager.hotkeyMode1,
                                accessibilityLabel: "Shortcut 1 mode",
                                accessibilityIdentifier: "settings-shortcut-1-mode"
                            )
                        }
                        hotkeyPicker(
                            binding: $hotkeyManager.selectedHotkey1,
                            accessibilityLabel: "Shortcut 1 key",
                            accessibilityIdentifier: "settings-shortcut-1-key"
                        )
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
                            hotkeyModePicker(
                                binding: $hotkeyManager.hotkeyMode2,
                                accessibilityLabel: "Shortcut 2 mode",
                                accessibilityIdentifier: "settings-shortcut-2-mode"
                            )
                            hotkeyPicker(
                                binding: $hotkeyManager.selectedHotkey2,
                                accessibilityLabel: "Shortcut 2 key",
                                accessibilityIdentifier: "settings-shortcut-2-key"
                            )
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
                            .accessibilityLabel("Remove second shortcut")
                            .accessibilityIdentifier("settings-remove-shortcut-2")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Shortcut 2")
                            InfoTip(
                                String(localized: "A second, independent key for the same recorder, with its own mode. Handy when you want a hold-to-talk key for quick asides and a toggle key for long dictation. The minus button removes it."),
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
                            String(localized: "Adds a second key that starts the recorder, with its own Toggle / Push to Talk / Hybrid mode. Both shortcuts stay active."),
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
                            String(localized: "Pastes the raw transcript of your most recent dictation again, exactly as the model heard it, with no AI enhancement. Useful when a paste landed in the wrong window, or when the enhanced version changed something you wanted kept."),
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
                            String(localized: "Pastes the AI-enhanced version of your most recent dictation again. Nothing is re-sent to the provider — this replays the result that was already produced."),
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
                            String(localized: "Runs the last recording through transcription again, using whatever model and language are selected now. Use it after switching to a more accurate model, or when a transcript came back garbled — the original audio is reused, so you don't have to speak again."),
                            doc: .shortcuts
                        )
                    }
                }

                // Custom Cancel - hierarchical
                ExpandableSettingsRow(
                    isExpanded: $isCustomCancelExpanded,
                    isEnabled: $isCustomCancelEnabled,
                    label: String(localized: "Custom Cancel Shortcut"),
                    infoMessage: String(localized: "Escape always discards the recording while the recorder is showing. Turn this on to add a second key that does the same, for when your hand is nowhere near Escape."),
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
                    label: String(localized: "Middle-Click Recording"),
                    infoMessage: String(localized: "Starts and stops recording with the middle mouse button — the scroll wheel click — so you can dictate without reaching for the keyboard. Leave it off if you use middle-click to open links in tabs."),
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
                            InfoTip(String(localized: "How long the middle button must be held before recording starts. Raise it if ordinary middle-clicks in your browser keep opening the recorder by accident; set it to 0 for an instant response."))
                        }
                    }
                }
            }

            // MARK: - Paste Options
            Section("Paste Options") {
                ExpandableSettingsRow(
                    isExpanded: $isRestoreClipboardExpanded,
                    isEnabled: $restoreClipboardAfterPaste,
                    label: String(localized: "Restore Clipboard After Paste"),
                    infoMessage: String(localized: "Pasting works by putting the transcript on the clipboard, which overwrites whatever you had copied. Turn this on to put your previous clipboard contents back once the paste has landed.")
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
                            InfoTip(String(localized: "How long to wait before putting your old clipboard contents back. Slower apps read the clipboard a moment after the paste; if you end up with the wrong text, increase this."))
                        }
                    }
                }

                Toggle(isOn: $useAppleScriptPaste) {
                    HStack(spacing: 4) {
                        Text("Use AppleScript Paste")
                        InfoTip(String(localized: "Enable this if pasting doesn't work with your keyboard layout (e.g. Neo2). Uses AppleScript instead of simulated key events."))
                    }
                }
            }
            }

            // MARK: - Recording Feedback
            if pane == nil || pane == .audio {
            Section("Recording Feedback") {
                // Sound Feedback
                ExpandableSettingsRow(
                    isExpanded: $isSoundFeedbackExpanded,
                    isEnabled: $soundManager.isEnabled,
                    label: String(localized: "Sound Feedback"),
                    infoMessage: String(localized: "Plays a short sound when recording starts and another when it stops, so you know the recorder is listening without looking at it. Expand to choose your own sounds.")
                ) {
                    CustomSoundSettingsView()
                }

                // Mute System Audio
                ExpandableSettingsRow(
                    isExpanded: $isMuteSystemExpanded,
                    isEnabled: $mediaController.isSystemMuteEnabled,
                    label: String(localized: "Mute Audio While Recording"),
                    infoMessage: String(localized: "Silences your Mac's output for the length of the recording, then restores the previous volume. Stops music or a video call leaking into the microphone and being transcribed as speech.")
                ) {
                    Toggle(isOn: $mediaController.skipMuteWithHeadphones) {
                        HStack(spacing: 4) {
                            Text("Keep Playing on Headphones")
                            InfoTip(String(localized: "Skips the mute for wired headphones, Bluetooth headsets and USB headsets that include an input. USB speakers or DACs, HDMI, AirPlay, and built-in or external speakers are treated as unsafe and still mute."))
                        }
                    }

                    if audioOutputRouteMonitor.isAmbiguousAnalogOutput {
                        AnalogHeadphoneConfirmationControl()
                    }

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
                            InfoTip(String(localized: "How long after recording stops before the volume comes back. A second or two keeps audio from returning over the top of the paste."))
                        }
                    }
                }

                MicTestView()
            }
            }

            // MARK: - Power Mode
            if pane == nil || pane == .shortcutsAutomation {
                PowerModeSection()
            }

            // MARK: - Interface
            if pane == nil || pane == .general {
            Section("Interface") {
                Picker(selection: $recorderUIManager.recorderType) {
                    Text("Notch").tag("notch")
                    Text("Mini").tag("mini")
                } label: {
                    HStack(spacing: 4) {
                        Text("Recorder Style")
                        InfoTip(String(localized: "Where the recorder appears while you dictate. Notch sits in the menu bar area at the top of the screen, around the camera housing on Macs that have one. Mini is a small floating pill you can drag anywhere."))
                    }
                }
                .pickerStyle(.segmented)

            }
            }

            // MARK: - Experimental
            if pane == nil || pane == .advancedDiagnostics {
                ExperimentalSection()
            }

            // MARK: - General
            if pane == nil || pane == .general {
            Section("General") {
                Toggle(isOn: $menuBarManager.isMenuBarOnly) {
                    HStack(spacing: 4) {
                        Text("Hide Dock Icon")
                        InfoTip(String(localized: "Removes Zerm from the Dock and the app switcher, leaving only the menu bar icon. Everything keeps working; open this window again from the menu bar."))
                    }
                }

                // Not `LaunchAtLogin.Toggle` — it re-reads SMAppService.status (a blocking
                // XPC call) on every body evaluation. See `LaunchAtLoginStore`.
                Toggle(isOn: launchAtLogin.binding) {
                    HStack(spacing: 4) {
                        Text("Launch at Login")
                        InfoTip(String(localized: "Starts Zerm automatically when you log in, so your dictation shortcut works without opening the app first."))
                    }
                }
                .onAppear { launchAtLogin.loadIfNeeded() }

                Toggle(isOn: $autoUpdateCheck) {
                    HStack(spacing: 4) {
                        Text("Auto-check Updates")
                        InfoTip(String(localized: "Looks for new versions in the background and tells you when one is ready. Nothing installs on its own — you still choose when to update."))
                    }
                }
                .onChange(of: autoUpdateCheck) { _, newValue in
                    updaterViewModel.toggleAutoUpdates(newValue)
                }

                Toggle(isOn: $enableAnnouncements) {
                    HStack(spacing: 4) {
                        Text("Show Announcements")
                        InfoTip(
                            String(localized: "Shows occasional in-app notes about new features and known issues. Turn it off for a completely quiet app."),
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
                    Button {
                        if updaterViewModel.updateAvailable {
                            updaterViewModel.installPendingUpdate()
                        } else {
                            updaterViewModel.checkForUpdates()
                        }
                    } label: {
                        Text(updaterViewModel.updateAvailable
                             ? LocalizedStringKey("Install Update…")
                             : LocalizedStringKey("Check for Updates"))
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
                    InfoTip(String(localized: "Shows the welcome and setup screens again the next time you launch Zerm. Your settings, prompts and history are left alone."))
                }

                if let error = updaterViewModel.lastErrorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            }

            // MARK: - Privacy
            if pane == nil || pane == .storageBackup {
            Section {
                AudioCleanupSettingsView()
            } header: {
                Text("Privacy")
            } footer: {
                Text("Control how Zerm handles your transcription data and audio recordings.")
            }
            }

            // MARK: - Backup
            if pane == nil || pane == .storageBackup {
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
                        InfoTip(String(localized: "Writes a single file containing your settings, prompts, Power Modes, dictionary and custom models. Keep it as a backup or use it to set up Zerm the same way on another Mac. API keys are not included."))
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
                        InfoTip(String(localized: "Loads a previously exported file. This overwrites your current settings, prompts, Power Modes and dictionary, so export first if you want a way back."))
                    }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Export or import all your settings, prompts, power modes, dictionary, and custom models.")
            }
            }

            // MARK: - Diagnostics
            if pane == nil || pane == .advancedDiagnostics {
            Section("Diagnostics") {
                DiagnosticsSettingsView()
            }
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
    private var shortcutHelp: String {
        String(localized: "The key that opens the recorder and starts dictation. Toggle starts on one press and stops on the next; Push to Talk records only while the key is held; Hybrid does both — a quick tap toggles, holding for longer than half a second records until you let go. Choose Custom to record any key combination you like.")
    }

    @ViewBuilder
    private func hotkeyPicker(
        binding: Binding<HotkeyManager.HotkeyOption>,
        accessibilityLabel: LocalizedStringKey,
        accessibilityIdentifier: String
    ) -> some View {
        Picker("", selection: binding) {
            ForEach(HotkeyManager.HotkeyOption.allCases, id: \.self) { option in
                Text(LocalizedStringKey(option.displayName)).tag(option)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(LocalizedStringKey(binding.wrappedValue.displayName)))
        .accessibilityIdentifier(accessibilityIdentifier)
        .fixedSize()
    }

    @ViewBuilder
    private func hotkeyModePicker(
        binding: Binding<HotkeyManager.HotkeyMode>,
        accessibilityLabel: LocalizedStringKey,
        accessibilityIdentifier: String
    ) -> some View {
        Picker("", selection: binding) {
            ForEach(HotkeyManager.HotkeyMode.allCases, id: \.self) { mode in
                Text(LocalizedStringKey(mode.displayName)).tag(mode)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(LocalizedStringKey(binding.wrappedValue.displayName)))
        .accessibilityIdentifier(accessibilityIdentifier)
        .fixedSize()
    }
}

// MARK: - Expandable Settings Row (entire row clickable)

struct ExpandableSettingsRow<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isExpanded: Bool
    @Binding var isEnabled: Bool
    let label: String
    var infoMessage: String? = nil
    var infoURL: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isEnabled && isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .help(isExpanded ? "Collapse" : "Expand")
                .accessibilityLabel(isExpanded ? "Collapse options" : "Expand options")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }

            if isEnabled && isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.top, 12)
                .padding(.leading, 4)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)
        .onChange(of: isEnabled) { _, newValue in
            if newValue {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
            } else {
                isExpanded = false
            }
        }
    }

    private func toggleExpanded() {
        guard isEnabled else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isExpanded.toggle()
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
                label: String(localized: "Power Mode"),
                infoMessage: String(localized: "Apply custom settings based on active app or website."),
                infoURL: Links.docString(.powerMode)
            ) {
                Toggle(isOn: $powerModePersistSettings) {
                    HStack(spacing: 4) {
                        Text("Persist Configured Preferences")
                        InfoTip(String(localized: "When enabled, Power Mode preferences stay active after you stop recording instead of reverting to your original preferences. They will only change when a different Power Mode activates."))
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
    @AppStorage("UseVoiceProcessingIO") private var useVoiceProcessingIO = false

    var body: some View {
        Section {
            Toggle(isOn: $useVoiceProcessingIO) {
                HStack(spacing: 4) {
                    Text("Echo Cancel / AGC")
                    InfoTip(String(localized: "Uses VoiceProcessingIO for acoustic echo cancellation and automatic gain control. Helpful in noisy rooms or when speakers are on. Restart recording after changing."))
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
