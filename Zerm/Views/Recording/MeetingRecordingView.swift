import SwiftUI
import UniformTypeIdentifiers

/// The Recording tab: start a meeting, watch it come in, read the transcript as it lands.
struct MeetingRecordingView: View {
    @EnvironmentObject private var engine: ZermEngine
    @StateObject private var controller: MeetingRecordingController

    @StateObject private var store = MeetingRecordingStore()
    @StateObject private var detector = MeetingAppDetector()

    @AppStorage("meetingCaptureMicrophone") private var captureMicrophone = true
    @AppStorage("meetingCaptureSystemAudio") private var captureSystemAudio = true
    @AppStorage("meetingLiveTranscript") private var liveTranscript = true
    @AppStorage("meetingIdentifySpeakers") private var identifySpeakers = true
    @AppStorage("meetingSummarise") private var summariseAfterMeeting = true
    @AppStorage("meetingAutoDetect") private var autoDetectMeetings = true

    @State private var importError: String?
    /// nil = the live pane. Selecting a past recording swaps the detail side, exactly as the
    /// live one behaves, so neither can drift into being a different kind of screen.
    @State private var selected: MeetingRecordingStore.Item?

    init(engine: ZermEngine? = nil) {
        _controller = StateObject(wrappedValue: MeetingRecordingController(engine: engine))
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
            detail
                .frame(minWidth: 460, maxWidth: .infinity)
        }
        .background(Color(.windowBackgroundColor))
        .task {
            store.reload()
            if autoDetectMeetings { detector.start() }
        }
        .onDisappear { detector.stop() }
        .onChange(of: autoDetectMeetings) { _, enabled in
            enabled ? detector.start() : detector.stop()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    selected = nil
                } label: {
                    Label(controller.isRecording ? "Recording…" : "New Recording",
                          systemImage: controller.isRecording ? "record.circle.fill" : "plus.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(controller.isRecording ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Import…") { importRecording() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if store.items.isEmpty {
                Text("Recordings appear here.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(14)
                Spacer()
            } else {
                List(selection: $selected) {
                    ForEach(store.items) { item in
                        sidebarRow(item)
                            .tag(item)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.folder])
                                }
                                Button("Move to Trash", role: .destructive) {
                                    if selected == item { selected = nil }
                                    store.delete(item)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func sidebarRow(_ item: MeetingRecordingStore.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            HStack(spacing: 6) {
                Text(Self.clock(item.duration))
                if item.speakerCount > 0 {
                    Label("\(item.speakerCount)", systemImage: "person.2.fill")
                }
                if item.wasInterrupted {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                }
                Text(Self.size(item.totalBytes))
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selected {
            ScrollView {
                MeetingDetailView(item: selected, sidecar: store.readSidecar(in: selected.folder))
                    .padding(24)
            }
        } else {
            liveDetail
        }
    }

    private var liveDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let message = importError {
                    banner(message, icon: "exclamationmark.triangle.fill", tint: .orange)
                }
                if let message = controller.errorMessage {
                    banner(message, icon: "exclamationmark.triangle.fill", tint: .orange)
                }
                if controller.session.systemAudioSilent {
                    banner(
                        "No system audio is coming through. If the other participants should be recorded, allow Zerm under System Settings › Privacy & Security › Audio Recording.",
                        icon: "speaker.slash.fill",
                        tint: .orange,
                        action: ("Open Settings", openAudioCaptureSettings)
                    )
                }
                if let detection = detector.detected, !controller.isRecording {
                    banner(
                        "\(detection.appName) is running. Record this meeting?",
                        icon: "video.fill",
                        tint: .accentColor,
                        action: ("Start Recording", { detector.dismiss(); toggle() }),
                        secondary: ("Not now", { detector.dismiss() })
                    )
                }
                sources
                if controller.isSummarising || controller.summary != nil || controller.summaryError != nil {
                    summarySection
                }
                transcriptSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.isRecording ? "Recording" : "Record a meeting")
                    .font(.system(size: 20, weight: .semibold))
                Text(controller.isRecording
                     ? Self.clock(controller.session.elapsed)
                     : "Captures the room through your microphone and the call through your Mac's audio.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            if controller.isRecording {
                levels
            }

            Button(action: toggle) {
                Text(controller.isRecording ? "Stop" : "Start")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 68)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isRecording ? .red : .accentColor)
            .disabled(!captureMicrophone && !captureSystemAudio)
        }
        .padding(20)
        .metricsCardSurface()
    }

    private var levels: some View {
        HStack(spacing: 14) {
            if captureMicrophone {
                LevelMeter(label: "Mic", db: controller.session.microphoneLevelDb)
            }
            if captureSystemAudio {
                LevelMeter(label: "System", db: controller.session.systemAudioLevelDb)
            }
        }
    }

    // MARK: - Sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Microphone — everyone in the room with you", isOn: $captureMicrophone)
            Toggle("System audio — everyone joining through the call", isOn: $captureSystemAudio)
            Toggle("Transcribe while recording", isOn: $liveTranscript)
            Toggle("Identify speakers in the room", isOn: $identifySpeakers)
                .disabled(!captureMicrophone)
            Toggle("Summarise when the meeting ends", isOn: $summariseAfterMeeting)
                .disabled(!liveTranscript)
            Toggle("Offer to record when a call app opens", isOn: $autoDetectMeetings)

            Text("Both are recorded as separate tracks, so you can tell your side from theirs.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .toggleStyle(.switch)
        .disabled(controller.isRecording)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricsCardSurface()
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold))
                if controller.isTranscribing && controller.isRecording {
                    ProgressView().controlSize(.small)
                }
                if controller.isPreparingDiarizer {
                    Text("preparing speaker model…")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else if controller.speakerCount > 0 {
                    Label("\(controller.speakerCount)", systemImage: "person.2.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .help("Distinct voices heard in the room")
                }
                Spacer()
                if !controller.segments.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.transcript, forType: .string)
                    }
                    .buttonStyle(.link)
                }
            }

            if controller.segments.isEmpty {
                Text(controller.isRecording
                     ? "Listening — the first lines appear once there is enough audio."
                     : "Nothing recorded yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.segments) { segment in
                        MeetingTranscriptRow(
                            start: segment.start,
                            speaker: controller.speakerLabel(for: segment),
                            text: segment.text
                        )
                    }
                }
            }

            if let recording = controller.lastRecording, !controller.isRecording {
                Divider().padding(.vertical, 4)
                HStack(spacing: 8) {
                    Text("Saved \(Self.clock(recording.duration)) to \(recording.folder.lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([recording.folder])
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricsCardSurface()
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Summary")
                    .font(.system(size: 13, weight: .semibold))
                if controller.isSummarising {
                    ProgressView().controlSize(.small)
                    Text("summarising…")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            if let message = controller.summaryError {
                Text("Could not summarise: \(message). The transcript and audio are saved either way.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let summary = controller.summary {
                if !summary.summary.isEmpty {
                    Text(summary.summary)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !summary.actionItems.isEmpty {
                    Text("Actions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle")
                                .font(.system(size: 6))
                                .padding(.top, 5)
                                .foregroundColor(.secondary)
                            Text(item)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !summary.chapters.isEmpty {
                    Text("Chapters")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    ForEach(Array(summary.chapters.enumerated()), id: \.offset) { _, chapter in
                        HStack(spacing: 8) {
                            Text(Self.clock(chapter.start))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                            Text(chapter.title)
                                .font(.system(size: 12))
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricsCardSurface()
    }

    // MARK: - Actions

    private func toggle() {
        if controller.isRecording {
            Task {
                await controller.stop()
                // Persist first: the transcript must be on disk whether or not the summary
                // model is reachable.
                persistLastRecording()
                store.reload()
                if summariseAfterMeeting {
                    await controller.summarise()
                    persistLastRecording()
                    store.reload()
                }
            }
        } else {
            var sources: MeetingRecordingSession.Sources = []
            if captureMicrophone { sources.insert(.microphone) }
            if captureSystemAudio { sources.insert(.systemAudio) }
            controller.start(
                sources: sources,
                transcribeLive: liveTranscript,
                identifySpeakers: identifySpeakers
            )
        }
    }

    /// Written only once the transcript has finished, so a reopened recording shows the same
    /// text the live view ended on rather than a truncated version of it.
    private func persistLastRecording() {
        guard let recording = controller.lastRecording else { return }
        store.writeSidecar(
            into: recording.folder,
            startedAt: recording.startedAt,
            duration: recording.duration,
            segments: controller.segments,
            speakerLabel: { controller.speakerLabel(for: $0) },
            speakerCount: controller.speakerCount,
            summary: controller.summary
        )
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Stable per-speaker colour so the same voice reads the same way down the transcript.
    private static func speakerTint(_ label: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal]
        return palette[abs(label.hashValue) % palette.count]
    }

    /// Adopts an existing audio file as a meeting, converting it to the recorder's own format
    /// so transcription, diarisation and summarising all work on it unchanged.
    private func importRecording() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MeetingRecordingStore.importableExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose recordings to add to your library"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                try store.importRecording(from: url)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func openAudioCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func banner(
        _ message: String,
        icon: String,
        tint: Color,
        action: (title: String, run: () -> Void)? = nil,
        secondary: (title: String, run: () -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(tint)
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let secondary {
                Button(secondary.title, action: secondary.run)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// A small horizontal meter. dBFS is compressed into a 0…1 bar over a 60 dB window, which is
/// where speech actually lives — a linear amplitude bar barely moves at conversational level.
private struct LevelMeter: View {
    let label: String
    let db: Float

    private var fraction: Double {
        let floorDb: Float = -60
        guard db > floorDb else { return 0 }
        return Double((db - floorDb) / -floorDb)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(fraction > 0.9 ? Color.orange : Color.accentColor)
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(width: 64, height: 5)
        }
    }
}
