import SwiftUI
import UniformTypeIdentifiers

struct SaveIconButton: View {
    let textToSave: String
    @State private var saved = false

    var body: some View {
        Menu {
            Button("Save as TXT") {
                saveFile(as: .plainText, extension: "txt")
            }
            Button("Save as MD") {
                saveFile(as: .text, extension: "md")
            }
        } label: {
            Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(saved ? .green : .secondary)
                .frame(width: 28, height: 28)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.9))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Save to file")
    }

    private func saveFile(as contentType: UTType, extension fileExtension: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(Self.suggestedFileName(for: textToSave)).\(fileExtension)"
        panel.title = String(localized: "Save Transcription")

        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            do {
                let content = fileExtension == "md" ? formatAsMarkdown(textToSave) : textToSave
                try content.write(to: url, atomically: true, encoding: .utf8)
                withAnimation { saved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { saved = false }
                }
            } catch {
                print("Failed to save file: \(error.localizedDescription)")
            }
        }
    }

    /// The first words of the text, joined with hyphens. Letters and digits of every script are
    /// kept, so a Hebrew transcript gets a Hebrew name instead of always falling back.
    nonisolated static func suggestedFileName(for text: String) -> String {
        let name = text
            .split(whereSeparator: \.isWhitespace)
            .prefix(8)
            .map { word in
                String(String.UnicodeScalarView(word.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
            }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()

        let trimmed = String(name.prefix(50)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? String(localized: "Transcription") : trimmed
    }

    private func formatAsMarkdown(_ text: String) -> String {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        return """
        # Transcription

        **Date:** \(timestamp)

        \(text)
        """
    }
}
