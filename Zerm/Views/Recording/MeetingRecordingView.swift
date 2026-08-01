import SwiftUI
import UniformTypeIdentifiers

/// The Recording tab.
///
/// Two dedicated screens behind one segmented control: **Record**, which is only what you look at
/// while a meeting runs, and **Library**, which is only past recordings. Everything you set once
/// lives in the settings panel behind the gear, not in the middle of either screen.
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

    @State private var tab: Tab = .record
    @State private var isShowingSettings = false
    @State private var importError: String?
    /// The recording opened inside the Library tab. nil means the list itself.
    @State private var selected: MeetingRecordingStore.Item?

    enum Tab: String, CaseIterable, Identifiable {
        case record = "Record"
        case library = "Library"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .record: return "record.circle"
            case .library: return "rectangle.stack.fill"
            }
        }
    }

    init(engine: ZermEngine? = nil) {
        _controller = StateObject(wrappedValue: MeetingRecordingController(engine: engine))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            Group {
                switch tab {
                case .record: recordTab
                case .library: libraryTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .slidingPanel(isPresented: $isShowingSettings, width: 400) {
            MeetingRecordingSettingsPanel(
                isRecording: controller.isRecording,
                onImport: importRecording,
                onDismiss: closeSettings
            )
        }
        .task {
            store.reload()
            if autoDetectMeetings { detector.start() }
        }
        .onDisappear { detector.stop() }
        .onChange(of: autoDetectMeetings) { _, enabled in
            enabled ? detector.start() : detector.stop()
        }
        // A detected call is only actionable on the Record screen, so go there rather than
        // showing a prompt the user cannot act on.
        .onChange(of: detector.detected) { _, detection in
            if detection != nil && !controller.isRecording { tab = .record }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            if tab == .library, selected != nil {
                Button {
                    selected = nil
                } label: {
                    Label("Library", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Back to all recordings")
            } else {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }

            Spacer()

            // The one thing that has to stay visible from either screen: whether tape is rolling.
            if controller.isRecording {
                Button { tab = .record } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text(Self.clock(controller.session.elapsed))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .help("Recording in progress")
            }

            if tab == .library {
                Button(action: importRecording) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Add existing audio files to your library")
            }

            Button {
                withAnimation(.smooth(duration: 0.3)) { isShowingSettings.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                    Text("Settings")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isShowingSettings ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Capture sources, transcript and library settings")
            .accessibilityLabel("Recording settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Record tab

    private var recordTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                transportCard

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

                if controller.isSummarising || controller.summary != nil || controller.summaryError != nil {
                    summaryCard
                }

                transcriptCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transportCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        if controller.isRecording {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                        }
                        Text(controller.isRecording ? "Recording" : "Record a meeting")
                            .font(.system(size: 20, weight: .semibold))
                    }

                    if controller.isRecording {
                        Text(Self.clock(controller.session.elapsed))
                            .font(.system(size: 30, weight: .light))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                    } else {
                        Text("Captures the room through your microphone and the call through your Mac's audio.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                if controller.isRecording {
                    HStack(spacing: 14) {
                        if captureMicrophone {
                            LevelMeter(label: "Mic", db: controller.session.microphoneLevelDb)
                        }
                        if captureSystemAudio {
                            LevelMeter(label: "System", db: controller.session.systemAudioLevelDb)
                        }
                    }
                }

                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: controller.isRecording ? "stop.fill" : "record.circle")
                        Text(controller.isRecording ? "Stop" : "Start")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 76)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isRecording ? .red : .accentColor)
                .disabled(!hasSource)
            }

            Divider()

            if hasSource {
                captureSummary
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("No capture source is on, so there is nothing to record.")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Open Settings") {
                        withAnimation(.smooth(duration: 0.3)) { isShowingSettings = true }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .metricsCardSurface()
    }

    /// What the next recording will do, read-only. Changing any of it is the settings panel's job.
    private var captureSummary: some View {
        HStack(spacing: 8) {
            if captureMicrophone { CaptureChip(icon: "mic.fill", label: "Microphone") }
            if captureSystemAudio { CaptureChip(icon: "speaker.wave.2.fill", label: "System audio") }
            if liveTranscript { CaptureChip(icon: "text.alignleft", label: "Live transcript") }
            if liveTranscript && identifySpeakers && captureMicrophone {
                CaptureChip(icon: "person.2.fill", label: "Speakers")
            }
            if liveTranscript && summariseAfterMeeting { CaptureChip(icon: "sparkles", label: "Summary") }

            Spacer()

            Button("Change") {
                withAnimation(.smooth(duration: 0.3)) { isShowingSettings = true }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(controller.isRecording)
        }
    }

    private var hasSource: Bool { captureMicrophone || captureSystemAudio }

    // MARK: - Transcript

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
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
                    .font(.system(size: 12))
                }
            }

            if controller.segments.isEmpty {
                emptyTranscript
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
                    Spacer()
                    Button("Open in Library") {
                        selected = store.items.first { $0.folder == recording.folder }
                        tab = .library
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
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

    @ViewBuilder
    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 4) {
            if controller.isRecording && !liveTranscript {
                Text("Transcribing while recording is off, so the transcript is not being written.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Text(controller.isRecording
                     ? "Listening — the first lines appear once there is enough audio."
                     : "Nothing recorded yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryCard: some View {
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

    // MARK: - Library tab

    @ViewBuilder
    private var libraryTab: some View {
        if let item = selected {
            ScrollView {
                MeetingDetailView(item: item, sidecar: store.readSidecar(in: item.folder))
                    .padding(24)
            }
        } else {
            MeetingLibraryView(
                store: store,
                onOpen: { selected = $0 },
                onImport: importRecording
            )
        }
    }

    // MARK: - Actions

    private func closeSettings() {
        withAnimation(.smooth(duration: 0.3)) { isShowingSettings = false }
    }

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
            tab = .record
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
        importError = nil
        for url in panel.urls {
            do {
                _ = try store.importRecording(from: url)
            } catch {
                importError = error.localizedDescription
            }
        }
        if importError == nil {
            closeSettings()
            selected = nil
            tab = .library
        } else {
            tab = .record
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

    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// One read-only fact about what the next recording will capture.
private struct CaptureChip: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
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
