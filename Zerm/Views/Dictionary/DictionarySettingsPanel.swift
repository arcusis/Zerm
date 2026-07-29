import SwiftUI
import KeyboardShortcuts

struct DictionarySettingsPanel: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("Dictionary Settings")
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
            .overlay(
                Divider().opacity(0.5), alignment: .bottom
            )

            // Content
            Form {
                Section {
                    LabeledContent {
                        KeyboardShortcuts.Recorder(for: .quickAddToDictionary)
                            .controlSize(.small)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Quick Add to Dictionary")
                            InfoTip(
                                "Opens a small panel from anywhere so you can add a word or a replacement without coming back to this window. Handy the moment a transcript gets a name wrong — fix it once and later dictations get it right.",
                                doc: .dictionary
                            )
                        }
                    }
                } header: {
                    Text("Shortcuts")
                }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}
