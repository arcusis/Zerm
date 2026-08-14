import SwiftUI
import SwiftData

struct AudioCleanupSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    // Audio cleanup settings
    @AppStorage("IsTranscriptionCleanupEnabled") private var isTranscriptionCleanupEnabled = false
    @AppStorage("TranscriptionRetentionMinutes") private var transcriptionRetentionMinutes = 24 * 60
    @AppStorage("IsAudioCleanupEnabled") private var isAudioCleanupEnabled = true
    @AppStorage("AudioRetentionPeriod") private var audioRetentionPeriod = 14
    @State private var isPerformingCleanup = false
    @State private var isShowingConfirmation = false
    @State private var cleanupInfo: (fileCount: Int, totalSize: Int64, transcriptions: [Transcription]) = (0, 0, [])
    @State private var showResultAlert = false
    @State private var cleanupResult: (deletedCount: Int, errorCount: Int) = (0, 0)
    @State private var showTranscriptCleanupResult = false
    @State private var isShowingStatsResetConfirmation = false

    // Expansion states - collapsed by default
    @State private var isTranscriptExpanded = false
    @State private var isAudioExpanded = false
    @State private var isHandlingTranscriptToggle = false
    @State private var isHandlingAudioToggle = false

    var body: some View {
        Group {
            // Transcript cleanup - hierarchical
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Toggle(isOn: $isTranscriptionCleanupEnabled) {
                        HStack(spacing: 4) {
                            Text("Auto-delete Transcripts")
                            InfoTip(String(localized: "Automatically delete transcript history based on the retention period you set. This removes the transcripts themselves — your usage statistics on the Dashboard are stored separately and are never affected."))
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isTranscriptionCleanupEnabled && isTranscriptExpanded ? 90 : 0))
                        .opacity(isTranscriptionCleanupEnabled ? 1 : 0.4)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isHandlingTranscriptToggle else { return }
                    if isTranscriptionCleanupEnabled {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isTranscriptExpanded.toggle()
                        }
                    }
                }

                if isTranscriptionCleanupEnabled && isTranscriptExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(selection: $transcriptionRetentionMinutes) {
                            Text("Immediately").tag(0)
                            Text("1 hour").tag(60)
                            Text("1 day").tag(24 * 60)
                            Text("3 days").tag(3 * 24 * 60)
                            Text("7 days").tag(7 * 24 * 60)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Delete After")
                                InfoTip(
                                    String(localized: "How long a transcript stays in your history before it is removed, along with its audio. Immediately means nothing is kept at all — the text is pasted and then dropped, so there is no history to search or copy from later."),
                                    doc: .privacyRetention
                                )
                            }
                        }

                        HStack(spacing: 4) {
                            Button("Run Cleanup Now") {
                                Task {
                                    await TranscriptionAutoCleanupService.shared.runManualCleanup(modelContext: modelContext)
                                    await MainActor.run {
                                        showTranscriptCleanupResult = true
                                    }
                                }
                            }
                            InfoTip(String(localized: "Applies the retention period above right now instead of waiting for the next scheduled sweep. Anything older than the period is deleted and cannot be recovered."))
                        }
                    }
                    .padding(.top, 12)
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isTranscriptExpanded)
            .alert("Transcript Cleanup", isPresented: $showTranscriptCleanupResult) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Cleanup complete.")
            }
            .onChange(of: isTranscriptionCleanupEnabled) { _, newValue in
                isHandlingTranscriptToggle = true
                if newValue {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTranscriptExpanded = true
                    }
                    AudioCleanupManager.shared.stopAutomaticCleanup()
                } else {
                    isTranscriptExpanded = false
                    if isAudioCleanupEnabled {
                        AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isHandlingTranscriptToggle = false
                }
            }

            // Audio cleanup - only show if transcript cleanup is disabled
            if !isTranscriptionCleanupEnabled {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Toggle(isOn: $isAudioCleanupEnabled) {
                            HStack(spacing: 4) {
                                Text("Auto-delete Audio Files")
                                InfoTip(String(localized: "Automatically delete audio recordings while keeping text transcripts intact. Usage statistics on the Dashboard are not affected."))
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(isAudioCleanupEnabled && isAudioExpanded ? 90 : 0))
                            .opacity(isAudioCleanupEnabled ? 1 : 0.4)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isHandlingAudioToggle else { return }
                        if isAudioCleanupEnabled {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isAudioExpanded.toggle()
                            }
                        }
                    }

                    if isAudioCleanupEnabled && isAudioExpanded {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker(selection: $audioRetentionPeriod) {
                                Text("1 day").tag(1)
                                Text("3 days").tag(3)
                                Text("7 days").tag(7)
                                Text("14 days").tag(14)
                                Text("30 days").tag(30)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Keep Audio For")
                                    InfoTip(
                                        String(localized: "How long recordings stay on disk before being deleted. The transcripts are kept either way — only the audio goes, which is what takes up the space. Keep a week or two if you use Retry Last Transcription, since that needs the original audio."),
                                        doc: .privacyRetention
                                    )
                                }
                            }

                            HStack(spacing: 4) {
                                Button {
                                    Task {
                                        await MainActor.run { isPerformingCleanup = true }
                                        let info = await AudioCleanupManager.shared.getCleanupInfo(modelContext: modelContext)
                                        await MainActor.run {
                                            cleanupInfo = info
                                            isPerformingCleanup = false
                                            isShowingConfirmation = true
                                        }
                                    }
                                } label: {
                                    Text(isPerformingCleanup
                                         ? LocalizedStringKey("Analyzing...")
                                         : LocalizedStringKey("Run Cleanup Now"))
                                }
                                .disabled(isPerformingCleanup)
                                InfoTip(String(localized: "Finds audio files older than the period above and shows how many there are, and how much space they use, before you confirm the deletion."))
                            }
                        }
                        .padding(.top, 12)
                        .padding(.leading, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isAudioExpanded)
                .alert("Audio Cleanup", isPresented: $isShowingConfirmation) {
                    Button("Cancel", role: .cancel) { }

                    if cleanupInfo.fileCount > 0 {
                        Button(deleteFilesTitle, role: .destructive) {
                            Task {
                                await MainActor.run { isPerformingCleanup = true }
                                let result = AudioCleanupManager.shared.runCleanupForTranscriptions(
                                    modelContext: modelContext,
                                    transcriptions: cleanupInfo.transcriptions
                                )
                                await MainActor.run {
                                    cleanupResult = result
                                    isPerformingCleanup = false
                                    showResultAlert = true
                                }
                            }
                        }
                    }
                } message: {
                    if cleanupInfo.fileCount > 0 {
                        Text(deleteConfirmationMessage)
                    } else {
                        Text("No audio files were found beyond the retention period.")
                    }
                }
                .alert("Cleanup Complete", isPresented: $showResultAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    if cleanupResult.errorCount > 0 {
                        Text(cleanupPartialResultMessage)
                    } else {
                        Text(cleanupSuccessMessage)
                    }
                }
                .onChange(of: isAudioCleanupEnabled) { _, newValue in
                    isHandlingAudioToggle = true
                    if newValue {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isAudioExpanded = true
                        }
                    } else {
                        isAudioExpanded = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isHandlingAudioToggle = false
                    }
                }
            }

            // Dashboard statistics live in their own store, so neither retention control
            // above reaches them. This is the only way to clear them.
            HStack(spacing: 4) {
                Button("Reset Statistics", role: .destructive) {
                    isShowingStatsResetConfirmation = true
                }
                InfoTip(
                    String(localized: "Permanently clears every recorded day on the Dashboard, along with the Read Aloud totals. Your transcripts and audio recordings are left alone — those have their own controls above. This cannot be undone, and the numbers do not come back: they are not rebuilt from your transcripts afterwards, even if you have kept every one of them."),
                    doc: .privacyRetention
                )
            }
            .confirmationDialog(
                "Reset Statistics?",
                isPresented: $isShowingStatsResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset Statistics", role: .destructive) {
                    UsageStatsService.shared.resetAll()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Every recorded day and the Read Aloud totals will be deleted. Transcripts and audio are not affected. This cannot be undone.")
            }
        }
    }

    private var deleteFilesTitle: String {
        String(localized: "audio_cleanup_delete_files \(cleanupInfo.fileCount)")
    }

    private var deleteConfirmationMessage: String {
        let size = AudioCleanupManager.shared.formatFileSize(cleanupInfo.totalSize)
        return String(localized: "audio_cleanup_delete_confirmation \(cleanupInfo.fileCount) \(size)")
    }

    private var cleanupPartialResultMessage: String {
        String(localized: "audio_cleanup_result_counts \(cleanupResult.deletedCount) \(cleanupResult.errorCount)")
    }

    private var cleanupSuccessMessage: String {
        String(localized: "audio_cleanup_deleted_files \(cleanupResult.deletedCount)")
    }
}
