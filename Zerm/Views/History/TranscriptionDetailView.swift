import SwiftUI
import SwiftData

struct TranscriptionDetailView: View {
    @Bindable var transcription: Transcription
    var onInfoTap: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var engine: ZermEngine
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @State private var isWorking = false
    @State private var editedText: String = ""
    @State private var isEditing = false

    private var hasAudioFile: Bool {
        if let urlString = transcription.audioFileURL,
           let url = URL(string: urlString),
           FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        return false
    }

    private var displayText: String { transcription.displayText }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 16) {
                    if isEditing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Edit transcript")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.7))
                            TextEditor(text: $editedText)
                                .font(.system(size: 14))
                                .frame(minHeight: 120)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
                            HStack {
                                Button("Save") {
                                    transcription.text = editedText
                                    try? modelContext.save()
                                    // Suggest dictionary entries from user edits.
                                    DictionarySuggestion.suggestFromEdit(
                                        original: displayText,
                                        edited: editedText,
                                        modelContext: modelContext
                                    )
                                    isEditing = false
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Button("Cancel") { isEditing = false }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        MessageBubble(
                            label: "Original",
                            text: transcription.text,
                            isEnhanced: false
                        )

                        if transcription.hasEnhancement, let enhancedText = transcription.enhancedText {
                            MessageBubble(
                                label: "Enhanced",
                                text: enhancedText,
                                isEnhanced: true
                            )
                        }
                    }
                }
                .padding(16)
            }

            // History workspace actions
            HStack(spacing: 8) {
                Button {
                    editedText = transcription.text
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .controlSize(.small)

                if hasAudioFile {
                    Button {
                        retranscribe()
                    } label: {
                        Label("Re-transcribe", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(isWorking)
                }

                Menu {
                    Button("Summarize") { runLocalAction(.summarize) }
                    Button("Translate to English") { runLocalAction(.translate) }
                    Button("More formal") { runLocalAction(.formal) }
                    Button("More casual") { runLocalAction(.casual) }
                    if enhancementService.isConfigured {
                        Button("Re-enhance") { reEnhance() }
                    }
                } label: {
                    Label("AI actions", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(isWorking || transcription.text.isEmpty)

                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            if hasAudioFile, let urlString = transcription.audioFileURL,
               let url = URL(string: urlString) {
                VStack(spacing: 0) {
                    Divider()

                    AudioPlayerView(url: url, transcription: transcription, onInfoTap: onInfoTap)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func retranscribe() {
        guard let urlString = transcription.audioFileURL,
              let url = URL(string: urlString),
              FileManager.default.fileExists(atPath: url.path) else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            guard let model = transcriptionModelManager.currentTranscriptionModel else {
                NotificationManager.shared.showNotification(title: "No model selected", type: .error)
                return
            }
            do {
                let service = AudioTranscriptionService(
                    modelContext: modelContext,
                    serviceRegistry: engine.serviceRegistry,
                    enhancementService: enhancementService
                )
                let result = try await service.retranscribeAudio(from: url, using: model)
                transcription.text = result.text
                transcription.enhancedText = result.enhancedText
                try? modelContext.save()
                NotificationManager.shared.showNotification(title: "Re-transcribed", type: .success)
            } catch {
                NotificationManager.shared.showNotification(
                    title: "Re-transcribe failed: \(error.localizedDescription)",
                    type: .error
                )
            }
        }
    }

    private func reEnhance() {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let (enhanced, _, _) = try await enhancementService.enhance(transcription.text)
                transcription.enhancedText = enhanced
                try? modelContext.save()
                NotificationManager.shared.showNotification(title: "Enhanced", type: .success)
            } catch {
                NotificationManager.shared.showNotification(
                    title: "Enhance failed: \(error.localizedDescription)",
                    type: .error
                )
            }
        }
    }

    private enum LocalAction {
        case summarize, translate, formal, casual

        var system: String {
            switch self {
            case .summarize: return "Summarize the transcript in a few clear sentences. Reply with only the summary."
            case .translate: return "Translate the transcript into natural English. Reply with only the translation."
            case .formal: return "Rewrite the transcript in a more formal tone. Reply with only the rewritten text."
            case .casual: return "Rewrite the transcript in a more casual, conversational tone. Reply with only the rewritten text."
            }
        }
    }

    private func runLocalAction(_ action: LocalAction) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let result = try await LocalLLMModelManager.shared.generate(
                    system: action.system,
                    user: transcription.text,
                    maxNewTokens: 400
                )
                transcription.enhancedText = result
                try? modelContext.save()
                NotificationManager.shared.showNotification(title: "Done", type: .success)
            } catch {
                NotificationManager.shared.showNotification(
                    title: "Local AI failed: \(error.localizedDescription)",
                    type: .error
                )
            }
        }
    }
}

/// Diffs user edits against original text to suggest vocabulary words.
@MainActor
enum DictionarySuggestion {
    static func suggestFromEdit(original: String, edited: String, modelContext: ModelContext) {
        let originalWords = Set(original.lowercased().split { !$0.isLetter }.map(String.init))
        let editedWords = edited.split { !$0.isLetter }.map(String.init)
        var suggestions: [String] = []
        for word in editedWords {
            let lower = word.lowercased()
            guard word.count >= 4, !originalWords.contains(lower) else { continue }
            // Prefer capitalized / multi-case proper nouns.
            if word.first?.isUppercase == true {
                suggestions.append(word)
            }
        }
        guard !suggestions.isEmpty else { return }
        let unique = Array(Set(suggestions)).prefix(5)
        let joined = unique.joined(separator: ", ")
        NotificationManager.shared.showNotification(
            title: "Add to dictionary? \(joined)",
            type: .info,
            duration: 6.0,
            actionButton: (label: "Add", action: {
                let existing = (try? modelContext.fetch(FetchDescriptor<VocabularyWord>())) ?? []
                for word in unique {
                    _ = DictionaryService.addVocabularyWords(word, existing: existing, context: modelContext)
                }
            })
        )
    }
}

private struct MessageBubble: View {
    let label: String
    let text: String
    let isEnhanced: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if isEnhanced { Spacer(minLength: 60) }

            VStack(alignment: isEnhanced ? .leading : .trailing, spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 12)

                ScrollView {
                    Text(text)
                        .font(.system(size: 14, weight: .regular))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .frame(maxHeight: 350)
                .background {
                    if isEnhanced {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.accentColor.opacity(0.2))
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.thinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                            )
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    CopyIconButton(textToCopy: text)
                        .padding(8)
                }
            }

            if !isEnhanced { Spacer(minLength: 60) }
        }
    }


}
