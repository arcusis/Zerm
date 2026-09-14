import AppKit
import SwiftUI

/// A finished file transcript: speaker-coloured paragraphs with timestamps that play the audio
/// from that point, inline speaker renaming, copy and export. Opened from Transcribe File and
/// from History; speaker names are saved to the transcript's sidecar and its History row.
struct FileTranscriptView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var player = AudioPlayerManager()
    @State private var transcript: FileTranscript
    @State private var copied = false
    @State private var exportError: String?
    /// Resolved once: History's audio cleanup may have removed the recording.
    @State private var audioURL: URL?

    private let closeTitle: LocalizedStringKey
    private let closeSystemImage: String
    private let onClose: () -> Void

    init(
        transcript: FileTranscript,
        closeTitle: LocalizedStringKey,
        closeSystemImage: String = "chevron.backward",
        onClose: @escaping () -> Void
    ) {
        _transcript = State(initialValue: transcript)
        self.closeTitle = closeTitle
        self.closeSystemImage = closeSystemImage
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    notices

                    if audioURL != nil {
                        playerBar
                    }

                    if !transcript.speakers.isEmpty {
                        speakerNames
                    }

                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(transcript.paragraphs) { paragraph in
                            paragraphRow(paragraph)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 860, alignment: .leading)
            }
        }
        .onAppear {
            // The saved sidecar holds names renamed since the transcript was handed in.
            if let saved = FileTranscriptStore.recordings.load(transcript.transcriptionID) {
                transcript = saved
            }
            let url = FileTranscriptStore.recordings.audioURL(for: transcript.transcriptionID)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            audioURL = url
            player.loadAudio(from: url)
        }
        .onDisappear { player.cleanup() }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: exportError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Label(closeTitle, systemImage: closeSystemImage)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: transcript.sourceFileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(transcript.timestamp(transcript.duration)) · \(transcript.modelName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: copy) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }

            Menu {
                ForEach(FileTranscriptExporter.Format.allCases) { format in
                    Button(Self.title(for: format)) { export(format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var notices: some View {
        if transcript.speakerStatus == .failed {
            Label(
                "Speakers could not be identified, so this transcript has no speaker labels. The speaker model downloads on first use; check your connection and retry the file.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
        }
        if !transcript.gaps.isEmpty {
            let ranges = transcript.gaps
                .map { "\(transcript.timestamp($0.start))–\(transcript.timestamp($0.end))" }
                .joined(separator: ", ")
            Label("Some parts of the file could not be transcribed: \(ranges)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Audio

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button {
                player.isPlaying ? player.pause() : player.play()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.bordered)
            .help(player.isPlaying ? "Pause" : "Play")

            Text(verbatim: transcript.timestamp(player.currentTime))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            WaveformView(
                samples: player.waveformSamples,
                currentTime: player.currentTime,
                duration: player.duration,
                isLoading: player.isLoadingWaveform,
                onSeek: { player.seek(to: $0) }
            )
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func play(from time: TimeInterval) {
        player.seek(to: time)
        if !player.isPlaying { player.play() }
    }

    // MARK: - Speakers

    private var speakerNames: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers")
                .font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(transcript.speakers, id: \.index) { speaker in
                    SpeakerNameField(
                        name: transcript.name(forSpeaker: speaker.index),
                        defaultName: FileTranscript.defaultName(forSpeaker: speaker.index),
                        color: SpeakerPalette.color(for: speaker.index)
                    ) { name in
                        rename(speaker: speaker.index, to: name)
                    }
                }
            }
        }
    }

    // MARK: - Paragraphs

    private func paragraphRow(_ paragraph: FileTranscript.Paragraph) -> some View {
        let color = paragraph.speakerIndex.map(SpeakerPalette.color(for:)) ?? .secondary
        let isPlaying = player.isPlaying && player.currentTime >= paragraph.start && player.currentTime < paragraph.end
        let isRightToLeft = BidiText.isRightToLeft(paragraph.text) == true

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let speaker = paragraph.speakerIndex {
                    Text(verbatim: transcript.name(forSpeaker: speaker))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color)
                }
                Button {
                    play(from: paragraph.start)
                } label: {
                    Text(verbatim: transcript.timestamp(paragraph.start))
                        .font(.caption)
                        .monospacedDigit()
                }
                .buttonStyle(.borderless)
                .disabled(audioURL == nil)
                .help("Play from here")
            }

            Text(verbatim: paragraph.text)
                .textSelection(.enabled)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color.opacity(0.7))
                .frame(width: 3)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isPlaying ? 0.08 : 0))
        )
    }

    // MARK: - Actions

    private func rename(speaker: Int, to name: String) {
        var renamed = transcript
        renamed.rename(speaker: speaker, to: name)
        guard renamed != transcript else { return }
        transcript = renamed
        FileTranscriptionHistory(modelContext: modelContext, store: .recordings).update(renamed)
    }

    private func copy() {
        _ = ClipboardManager.copyToClipboard(transcript.plainText)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }

    private func export(_ format: FileTranscriptExporter.Format) {
        let panel = NSSavePanel()
        let baseName = (transcript.sourceFileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(baseName.isEmpty ? String(localized: "Transcription") : baseName).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileTranscriptExporter.export(transcript, as: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private static func title(for format: FileTranscriptExporter.Format) -> LocalizedStringKey {
        switch format {
        case .text: "Plain Text (.txt)"
        case .markdown: "Markdown (.md)"
        case .srt: "SubRip Subtitles (.srt)"
        case .vtt: "WebVTT Subtitles (.vtt)"
        case .json: "JSON (.json)"
        }
    }
}

/// A speaker's name, renamed in place. Committed on Return or when the field loses focus; an
/// empty name restores "Speaker N".
private struct SpeakerNameField: View {
    let name: String
    let defaultName: String
    let color: Color
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            TextField("Speaker name", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .frame(width: 130)
                .onSubmit(commit)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .help("Rename this speaker")
        .onAppear { text = name }
        .onChange(of: name) { _, newValue in
            text = newValue
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        onCommit(text)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = defaultName
        }
    }
}

enum SpeakerPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .red, .mint]

    static func color(for speaker: Int) -> Color {
        colors[speaker % colors.count]
    }
}
