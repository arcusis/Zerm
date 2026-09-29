import SwiftUI
import KeyboardShortcuts

struct EnhancementShortcutsView: View {
    @State private var shortcutRefresh = 0

    var body: some View {
        VStack(spacing: 8) {
            // Toggle AI Enhancement
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 4) {
                    Text("Toggle AI Enhancement")
                        .font(.system(size: 13))

                    InfoTip(
                        String(localized: "Quickly enable or disable AI enhancement while recording. Available only when Zerm is running and the recorder is visible."),
                        learnMoreURL: Links.docString(.enhancementShortcuts)
                    )
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    KeyboardShortcuts.Recorder(for: .toggleEnhancement) { _ in
                        shortcutRefresh += 1
                    }
                    .controlSize(.small)

                    if hasShortcutConflict {
                        Label("This shortcut is also assigned to another Zerm action.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Switch Enhancement Prompt
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 4) {
                    Text("Switch Enhancement Prompt")
                        .font(.system(size: 13))

                    InfoTip(
                        String(localized: "Switch between your saved prompts using ⌘1 through ⌘0 to activate the corresponding prompt in the order they are saved. Available only when Zerm is running and the recorder is visible."),
                        learnMoreURL: Links.docString(.enhancementShortcuts)
                    )
                }

                Spacer()

                HStack(spacing: 4) {
                    KeyChip(label: "⌘")
                    KeyChip(label: "1 – 0")
                }
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    KeyboardShortcuts.setShortcut(
                        KeyboardShortcuts.Name.toggleEnhancement.defaultShortcut,
                        for: .toggleEnhancement
                    )
                    shortcutRefresh += 1
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("enhancement-shortcuts-restore-defaults")
            }
        }
        .background(Color.clear)
        .onAppear { shortcutRefresh += 1 }
    }

    private var hasShortcutConflict: Bool {
        _ = shortcutRefresh
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleEnhancement) else { return false }

        return [
            KeyboardShortcuts.Name.toggleMiniRecorder,
            .toggleMiniRecorder2,
            .pasteLastTranscription,
            .pasteLastEnhancement,
            .retryLastTranscription,
            .cancelRecorder,
            .readSelectedTextAloud
        ].contains { KeyboardShortcuts.getShortcut(for: $0) == shortcut }
    }
}

// MARK: - Supporting Views
private struct KeyChip: View {
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        Color(NSColor.separatorColor).opacity(0.5),
                        lineWidth: 0.5
                    )
            )
    }
}
