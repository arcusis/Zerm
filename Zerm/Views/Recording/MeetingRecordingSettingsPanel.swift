import SwiftUI

/// Everything that configures a meeting recording, in one place.
///
/// These switches used to sit in the middle of the Recording tab, between the transport and the
/// transcript, so the screen you use while a meeting runs was mostly controls you set once. They
/// live here now, behind the same sliding settings panel Enhancement, Dictionary and Models use.
struct MeetingRecordingSettingsPanel: View {
    @AppStorage("meetingCaptureMicrophone") private var captureMicrophone = true
    @AppStorage("meetingCaptureSystemAudio") private var captureSystemAudio = true
    @AppStorage("meetingLiveTranscript") private var liveTranscript = true
    @AppStorage("meetingIdentifySpeakers") private var identifySpeakers = true
    @AppStorage("meetingSummarise") private var summariseAfterMeeting = true
    @AppStorage("meetingAutoDetect") private var autoDetectMeetings = true

    /// Capture settings cannot change mid-meeting — the tracks are already open.
    let isRecording: Bool
    let onImport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                if isRecording {
                    Section {
                        Label(
                            "A recording is in progress. Capture settings apply to the next one.",
                            systemImage: "record.circle.fill"
                        )
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    }
                }

                Section {
                    Toggle(isOn: $captureMicrophone) {
                        HStack(spacing: 4) {
                            Text("Microphone")
                            InfoTip("Records everyone in the room with you, through your input device.")
                        }
                    }
                    .disabled(isRecording)

                    Toggle(isOn: $captureSystemAudio) {
                        HStack(spacing: 4) {
                            Text("System Audio")
                            InfoTip("Records everyone joining through the call, straight from your Mac's audio output.")
                        }
                    }
                    .disabled(isRecording)

                    if !captureMicrophone && !captureSystemAudio {
                        Label("Pick at least one source, or there is nothing to record.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                } header: {
                    Text("Capture")
                } footer: {
                    Text("Both are written as separate tracks, so you can tell your side from theirs.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle(isOn: $liveTranscript) {
                        HStack(spacing: 4) {
                            Text("Transcribe While Recording")
                            InfoTip("Lines appear as the meeting runs instead of only after it ends.")
                        }
                    }
                    .disabled(isRecording)

                    Toggle(isOn: $identifySpeakers) {
                        HStack(spacing: 4) {
                            Text("Identify Speakers")
                            InfoTip("Separates the voices in the room and labels each transcript line. Needs the microphone.")
                        }
                    }
                    .disabled(isRecording || !captureMicrophone)

                    Toggle(isOn: $summariseAfterMeeting) {
                        HStack(spacing: 4) {
                            Text("Summarise When The Meeting Ends")
                            InfoTip("Writes a summary, action items and chapters once the transcript is complete. Needs a transcript.")
                        }
                    }
                    .disabled(!liveTranscript)
                } header: {
                    Text("Transcript")
                }

                Section {
                    Toggle(isOn: $autoDetectMeetings) {
                        HStack(spacing: 4) {
                            Text("Offer To Record When A Call App Opens")
                            InfoTip("Watches for Zoom, Meet, Teams and the like, and offers to start recording. Nothing starts on its own.")
                        }
                    }
                } header: {
                    Text("Automatic")
                }

                Section {
                    Button("Import Recordings…") { onImport() }

                    Button("Show Recordings Folder") {
                        guard let root = try? MeetingRecordingSession.recordingsRoot() else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Recordings stay on this Mac. Nothing is uploaded.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Recording Settings")
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}
