import SwiftUI

/// One past meeting: play it back, read the transcript, jump to any line.
///
/// Shares `MeetingTranscriptRow` with the live view rather than rendering its own transcript, so
/// a recording in progress and a recording being replayed cannot drift into looking like two
/// different features.
struct MeetingDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var controller: MeetingRecordingController
    let item: MeetingRecordingStore.Item
    let sidecar: MeetingRecordingStore.Sidecar?
    var onProcessed: () -> Void = {}

    @StateObject private var player = MeetingPlayer()
    @State private var isProcessing = false
    @State private var processingError: String?

    private var lines: [MeetingRecordingStore.Sidecar.Line] { sidecar?.segments ?? [] }
    /// Nothing is "playing now" before playback has started, so an untouched recording opens
    /// with a plain transcript rather than its first line lit up as if it were being spoken.
    private var activeLine: Int? {
        guard player.isPlaying || player.currentTime > 0 else { return nil }
        return sidecar?.line(at: player.currentTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            transport
            processingStatus
            if let summary = sidecar?.summary, !summary.isEmpty {
                summaryCard(summary)
            }
            transcript
        }
        .onAppear { player.load(item) }
        .onDisappear { player.stop() }
        .onChange(of: item.id) { _, _ in player.load(item) }
        .alert(
            "Could Not Process Recording",
            isPresented: Binding(
                get: { processingError != nil },
                set: { if !$0 { processingError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { processingError = nil }
        } message: {
            Text(processingError ?? String(localized: "Unknown processing error"))
        }
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 8) {
                        Text(Self.clock(item.duration))
                        if item.speakerCount > 0 {
                            Label("\(item.speakerCount)", systemImage: "person.2.fill")
                        }
                        if item.wasInterrupted {
                            Label("recovered", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                }

                Spacer()

                Button(action: processRecording) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(processTitle, systemImage: "waveform.badge.magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canProcess || isProcessing)
                .accessibilityIdentifier("process-meeting-detail")

                // Only offered when both sides were actually captured.
                if item.microphoneTrack != nil && item.systemAudioTrack != nil {
                    Picker("Playback track", selection: Binding(
                        get: { player.track },
                        set: { player.select(track: $0) }
                    )) {
                        ForEach(MeetingPlayer.Track.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(minWidth: 220, idealWidth: 260)
                }
            }

            if let message = player.errorMessage {
                Text(message).font(.system(size: 11)).foregroundColor(.orange)
            }

            HStack(spacing: 12) {
                Button(action: player.togglePlay) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .disabled(player.duration == 0)
                .accessibilityLabel(Text(playbackActionLabel))
                .accessibilityHint("Starts or pauses playback of this meeting recording.")

                Text(Self.clock(player.currentTime))
                    .font(.system(size: 11)).monospacedDigit().foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0, lead: 0) }
                    ),
                    in: 0...max(player.duration, 0.1)
                )
                .disabled(player.duration == 0)
                .accessibilityLabel("Playback position")
                .accessibilityValue(Text(playbackPositionValue))

                Text(Self.clock(player.duration))
                    .font(.system(size: 11)).monospacedDigit().foregroundColor(.secondary)
            }

            if item.microphoneTrack != nil && item.systemAudioTrack != nil {
                HStack(spacing: 8) {
                    Text("Track controls")
                        .font(.callout.weight(.medium))
                    Spacer()

                    Toggle(isOn: Binding(
                        get: { player.roomMuted },
                        set: { player.setMuted($0, for: .microphone) }
                    )) {
                        Label("Mute Room", systemImage: player.roomMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    }
                    .toggleStyle(.button)

                    Button {
                        player.toggleSolo(.microphone)
                    } label: {
                        Label(
                            "Solo Room",
                            systemImage: player.track == .microphone ? "checkmark.circle.fill" : "person.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityValue(selectionValue(player.track == .microphone))

                    Toggle(isOn: Binding(
                        get: { player.callMuted },
                        set: { player.setMuted($0, for: .systemAudio) }
                    )) {
                        Label("Mute Call", systemImage: player.callMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    }
                    .toggleStyle(.button)

                    Button {
                        player.toggleSolo(.systemAudio)
                    } label: {
                        Label(
                            "Solo Call",
                            systemImage: player.track == .systemAudio ? "checkmark.circle.fill" : "person.2.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityValue(selectionValue(player.track == .systemAudio))
                }
                .controlSize(.small)
            }
        }
        .padding(20)
        .metricsCardSurface()
    }

    private var playbackActionLabel: LocalizedStringKey {
        player.isPlaying ? "Pause recording playback" : "Play recording"
    }

    private var playbackPositionValue: String {
        let format = String(localized: "Playback position: %@ of %@")
        return String.localizedStringWithFormat(
            format,
            Self.clock(player.currentTime),
            Self.clock(player.duration)
        )
    }

    private func selectionValue(_ isSelected: Bool) -> Text {
        let key: LocalizedStringKey = isSelected ? "Selected" : "Not selected"
        return Text(key)
    }

    @ViewBuilder
    private var processingStatus: some View {
        if isProcessing {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: controller.processingProgress)
                    Text("Processing this recording with the selected Dictation model…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if item.wasInterrupted || !item.issues.isEmpty || item.transcript?.isEmpty != false {
            GroupBox {
                Label(processStatusMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var canProcess: Bool {
        switch controller.lifecycle.phase {
        case .idle, .ready, .partial, .failed:
            return true
        case .preflighting, .capturing, .stopping, .processing:
            return isProcessing
        }
    }

    private var processTitle: LocalizedStringKey {
        if item.transcript?.isEmpty != false { return "Process Recording" }
        if item.wasInterrupted || !item.issues.isEmpty { return "Retry Processing" }
        return "Re-transcribe"
    }

    private var processStatusMessage: LocalizedStringKey {
        if item.wasInterrupted { return "This recording was recovered and should be processed again." }
        if !item.issues.isEmpty { return "Processing finished with issues. You can retry with the selected model." }
        return "This recording has not been transcribed yet."
    }

    private func processRecording() {
        guard canProcess, !isProcessing else { return }
        isProcessing = true
        Task {
            await controller.process(item)
            processingError = controller.errorMessage
            isProcessing = false
            onProcessed()
        }
    }

    // MARK: - Summary

    private func summaryCard(_ summary: MeetingSummarizer.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.system(size: 13, weight: .semibold))
            if !summary.summary.isEmpty {
                Text(summary.summary).font(.system(size: 13)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !summary.actionItems.isEmpty {
                Text("Actions").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)").font(.system(size: 12)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !summary.chapters.isEmpty {
                Text("Chapters").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                ForEach(Array(summary.chapters.enumerated()), id: \.offset) { _, chapter in
                    Button {
                        player.seek(to: chapter.start)
                    } label: {
                        HStack(spacing: 8) {
                            Text(Self.clock(chapter.start))
                                .font(.system(size: 11)).monospacedDigit().foregroundColor(.secondary)
                            Text(chapter.title).font(.system(size: 12))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricsCardSurface()
    }

    // MARK: - Transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let text = item.transcript, !text.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.link)
                }
            }

            if lines.isEmpty {
                Text(item.transcript ?? String(localized: "No transcript for this recording."))
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Button {
                                player.seek(to: line.start)
                            } label: {
                                MeetingTranscriptRow(
                                    start: line.start,
                                    speaker: line.speaker,
                                    text: line.text,
                                    isActive: index == activeLine,
                                    isSpeakerEstimated: line.speakerConfidence
                                        == MeetingTranscriber.Segment.SpeakerConfidence.estimatedFromWindow.rawValue
                                )
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .accessibilityLabel(transcriptAccessibilityLabel(for: line))
                        }
                    }
                    // Follow the audio, but only while it is actually playing — otherwise
                    // reading ahead would keep yanking the view back.
                    .onChange(of: activeLine) { _, line in
                        guard player.isPlaying, let line else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            proxy.scrollTo(line, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricsCardSurface()
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func transcriptAccessibilityLabel(for line: MeetingRecordingStore.Sidecar.Line) -> Text {
        let speaker = line.speaker ?? String(localized: "Unknown speaker")
        let isEstimated = line.speakerConfidence
            == MeetingTranscriber.Segment.SpeakerConfidence.estimatedFromWindow.rawValue
        let format = isEstimated
            ? String(localized: "Play from %@. %@. Estimated speaker attribution. %@")
            : String(localized: "Play from %@. %@. %@")
        return Text(String.localizedStringWithFormat(format, Self.clock(line.start), speaker, line.text))
    }
}

/// One transcript line, used by both the live view and playback.
struct MeetingTranscriptRow: View {
    let start: TimeInterval
    let speaker: String?
    let text: String
    var isActive: Bool = false
    var isSpeakerEstimated: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(MeetingDetailView.clock(start))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                if let speaker {
                    Text(speaker)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Self.tint(speaker))
                    if isSpeakerEstimated {
                        Label("Estimated", systemImage: "questionmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Speaker attribution is estimated because exact word timing was unavailable.")
                            .accessibilityLabel("Estimated speaker attribution")
                    }
                }
            }
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.14) : .clear)
        )
        .accessibilityElement(children: .combine)
    }

    /// Stable per-speaker colour so one voice reads the same way down the transcript.
    ///
    /// Not `hashValue`: Swift seeds string hashing per process, so the same voice came back a
    /// different colour on every launch, and neighbouring labels could collide — "Speaker 1",
    /// "Speaker 2" and "Speaker 3" all landed on the same pink. Folding the bytes is stable
    /// across launches and puts labels that differ only in their last character on
    /// consecutive palette entries, which is exactly the case that matters here.
    static func tint(_ label: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal]
        let index = label.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % palette.count }
        return palette[index]
    }
}
