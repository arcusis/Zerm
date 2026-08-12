import SwiftUI

struct MeetingModelsView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.2.wave.2")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meeting Transcription Models")
                        .font(.title2.bold())
                    Text("Meetings use the same selected speech-to-text model and language as Dictation. Changes here apply to the next meeting and the next dictation.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()
            ModelManagementView()
        }
    }
}
