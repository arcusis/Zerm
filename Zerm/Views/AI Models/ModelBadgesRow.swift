import SwiftUI

/// Capability badges on a model card. The one place new badges are added.
struct ModelBadgesRow: View {
    let model: any TranscriptionModel

    var body: some View {
        HStack(spacing: 6) {
            if model.isHebrewOptimized {
                badge("Great in Hebrew", systemImage: "star.fill")
            } else if model.supportedLanguages["he"] != nil {
                badge("Hebrew", systemImage: "character.bubble")
            } else if model.isMultilingualModel {
                badge("No Hebrew", systemImage: "slash.circle")
            }
            if model.supportsStreaming {
                badge("Streaming", systemImage: "waveform")
            }
            if model.capabilities.contains(.vocabulary) {
                badge("Uses Dictionary", systemImage: "character.book.closed")
            }
            if model.capabilities.contains(.diarization) {
                badge("Speaker labels", systemImage: "person.2")
            }
        }
    }

    private func badge(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color(.secondaryLabelColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(.quaternaryLabelColor).opacity(0.3)))
            .lineLimit(1)
            .fixedSize()
    }
}
