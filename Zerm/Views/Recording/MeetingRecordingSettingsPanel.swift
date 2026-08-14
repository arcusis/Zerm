import SwiftUI

/// Feature-local presentation of the same meeting defaults used by native Settings.
struct MeetingRecordingSettingsPanel: View {
    let isRecording: Bool
    let onImport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            MeetingSettingsForm(isRecording: isRecording, onImport: onImport)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Meeting Settings")
                .font(.headline.weight(.semibold))

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close meeting settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}

/// Shared meeting defaults. Using one view keeps native Settings and the Meetings sheet bound to
/// the same keys without duplicating behavior or allowing capture settings to change mid-session.
struct MeetingSettingsForm: View {
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @AppStorage("meetingCaptureMicrophone") private var captureMicrophone = true
    @AppStorage("meetingCaptureSystemAudio") private var captureSystemAudio = true
    @AppStorage("meetingLiveTranscript") private var liveTranscript = true
    @AppStorage("meetingIdentifySpeakers") private var identifySpeakers = true
    @AppStorage("meetingSummarise") private var summariseAfterMeeting = true
    @AppStorage("SelectedLanguage") private var selectedLanguage = "auto"

    let isRecording: Bool
    var onImport: (() -> Void)? = nil

    var body: some View {
        Form {
            if isRecording {
                Section {
                    Label(
                        "A meeting is being recorded. Capture settings apply to the next meeting.",
                        systemImage: "record.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: $captureMicrophone) {
                    HStack(spacing: 4) {
                        Text("Microphone")
                        InfoTip(String(localized: "Records everyone in the room with you, through your input device."))
                    }
                }
                .disabled(isRecording)

                Toggle(isOn: $captureSystemAudio) {
                    HStack(spacing: 4) {
                        Text("Call Audio")
                        InfoTip(String(localized: "Records people joining through the selected meeting application. All system audio is available as an explicit fallback in meeting preflight."))
                    }
                }
                .disabled(isRecording)

                if !captureMicrophone && !captureSystemAudio {
                    Label(
                        "Pick at least one source, or there is nothing to record.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Capture")
            } footer: {
                Text("Room and call audio are saved as separate, synchronized tracks.")
            }

            Section {
                Toggle(isOn: $liveTranscript) {
                    HStack(spacing: 4) {
                        Text("Show Transcript While Recording")
                        InfoTip(String(localized: "Shows transcript lines during the meeting. Zerm still completes processing after recording ends."))
                    }
                }
                .disabled(isRecording)

                Toggle(isOn: $identifySpeakers) {
                    HStack(spacing: 4) {
                        Text("Identify Speakers")
                        InfoTip(String(localized: "Labels speakers in the room and in the call as their audio tracks are processed."))
                    }
                }
                .disabled(isRecording || (!captureMicrophone && !captureSystemAudio))

                Toggle(isOn: $summariseAfterMeeting) {
                    HStack(spacing: 4) {
                        Text("Create Summary After Recording")
                        InfoTip(String(localized: "Uses the selected local Ollama model to create a summary, action items and chapters after transcription completes. Availability is checked before recording starts."))
                    }
                }
                .disabled(isRecording)

                if let nativeAppleLanguageDisclosure {
                    Label(nativeAppleLanguageDisclosure, systemImage: "character.book.closed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Transcript")
            }

            if let onImport {
                Section {
                    Button("Import Recordings…", action: onImport)

                    Button("Show Recordings Folder") {
                        guard let root = try? MeetingRecordingSession.recordingsRoot() else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                } header: {
                    Text("Library")
                }
            }

            Section {
                Text("Recording files stay on this Mac. If the selected Dictation model is cloud-based, meeting audio is sent to that provider for transcription.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .toggleStyle(.switch)
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var nativeAppleLanguageDisclosure: String? {
        guard let model = transcriptionModelManager.currentTranscriptionModel,
              model.provider == .nativeApple else { return nil }
        return MeetingLanguagePresentation.resolve(
            provider: model.provider,
            requestedCode: selectedLanguage,
            supportedLanguages: LanguageDictionary.appleNative
        ).disclosure
    }
}
