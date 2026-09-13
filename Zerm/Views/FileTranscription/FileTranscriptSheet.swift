import SwiftUI

extension View {
    /// Presents the full transcript of a History row that Transcribe File created.
    func fileTranscriptSheet(for transcriptionID: UUID, isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            FileTranscriptSheet(transcriptionID: transcriptionID)
        }
    }
}

/// "Open Transcript" for History rows that have a file transcript. Hidden for every other row.
struct OpenFileTranscriptButton: View {
    let transcriptionID: UUID
    let action: () -> Void

    var body: some View {
        if FileTranscriptStore.recordings.hasTranscript(for: transcriptionID) {
            Button(action: action) {
                Label("Open Transcript", systemImage: "person.2.wave.2")
            }
        }
    }
}

private struct FileTranscriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var transcript: FileTranscript?

    init(transcriptionID: UUID) {
        _transcript = State(initialValue: FileTranscriptStore.recordings.load(transcriptionID))
    }

    var body: some View {
        Group {
            if let transcript {
                FileTranscriptView(transcript: transcript, closeTitle: "Done", closeSystemImage: "xmark") {
                    dismiss()
                }
            } else {
                ContentUnavailableView(
                    "Transcript Unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("The saved transcript for this recording could not be read.")
                )
            }
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 560, idealHeight: 720)
    }
}
