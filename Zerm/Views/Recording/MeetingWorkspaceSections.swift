import SwiftUI

enum MeetingLanguagePresentation {
    struct Result: Equatable {
        let code: String
        let displayName: String
        let disclosure: String?
    }

    static func resolve(
        provider: ModelProvider,
        requestedCode: String,
        supportedLanguages: [String: String],
        locale: Locale = .current
    ) -> Result {
        guard provider == .nativeApple, requestedCode == LanguagePreference.autoCode else {
            let name = requestedCode == LanguagePreference.autoCode
                ? String(localized: "Auto-detect")
                : localizedName(for: requestedCode, fallback: supportedLanguages[requestedCode], locale: locale)
            return .init(code: requestedCode, displayName: name, disclosure: nil)
        }

        let currentIdentifier = locale.identifier(.bcp47)
        let currentLanguage = locale.language.languageCode?.identifier
        let resolvedCode = supportedLanguages[currentIdentifier] != nil
            ? currentIdentifier
            : supportedLanguages.keys.sorted().first {
                Locale(identifier: $0).language.languageCode?.identifier == currentLanguage
            }
                ?? (supportedLanguages["en-US"] != nil ? "en-US" : supportedLanguages.keys.sorted().first)
                ?? "en-US"
        let name = localizedName(for: resolvedCode, fallback: supportedLanguages[resolvedCode], locale: locale)
        let format = String(localized: "Native Apple does not auto-detect. It will use the fixed language %@ for this meeting.")
        return .init(
            code: resolvedCode,
            displayName: name,
            disclosure: String.localizedStringWithFormat(format, name)
        )
    }

    private static func localizedName(for code: String, fallback: String?, locale: Locale) -> String {
        locale.localizedString(forIdentifier: code)
            ?? locale.localizedString(forLanguageCode: code)
            ?? fallback
            ?? code
    }
}

struct MeetingTranscriptItem: Identifiable {
    let id: UUID
    let start: TimeInterval
    let speaker: String?
    let isSpeakerEstimated: Bool
    let text: String
}

struct MeetingConfigurationSummary: View {
    let modelName: String
    let providerName: String
    let languageName: String
    let languageDisclosure: String?
    let usesCloud: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Dictation model", value: modelName)
            LabeledContent("Language", value: languageName)
            if let languageDisclosure {
                Label(languageDisclosure, systemImage: "character.book.closed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting-language-disclosure")
            }

            if usesCloud {
                Label {
                    Text("Meeting audio is sent to \(providerName) for transcription.")
                } icon: {
                    Image(systemName: "icloud.and.arrow.up")
                }
                .font(.callout)
                .foregroundStyle(Color.orange)
                .accessibilityIdentifier("meeting-cloud-disclosure")
            } else {
                Label {
                    Text("Transcription runs on this Mac with \(providerName).")
                } icon: {
                    Image(systemName: "lock.macwindow")
                }
                .font(.callout)
                .foregroundStyle(Color.secondary)
                .accessibilityIdentifier("meeting-local-disclosure")
            }
        }
    }
}

struct MeetingPreflightView: View {
    @Binding var captureMicrophone: Bool
    @Binding var captureSystemAudio: Bool
    @Binding var usesAllSystemAudio: Bool
    @Binding var selectedApplicationBundleID: String
    @Binding var liveTranscript: Bool
    @Binding var identifySpeakers: Bool
    @Binding var summariseAfterMeeting: Bool

    let applications: [MeetingCaptureApplicationSource.Application]
    let modelName: String
    let providerName: String
    let languageName: String
    let languageDisclosure: String?
    let usesCloud: Bool
    let hasSelectedModel: Bool
    let summarySnapshot: MeetingSummarySnapshot
    let summaryAvailability: Bool?
    let isCheckingSummaryAvailability: Bool
    let start: () -> Void
    let openModels: () -> Void
    let refreshApplications: () -> Void
    let refreshSummaryAvailability: () -> Void

    private var hasSource: Bool { captureMicrophone || captureSystemAudio }
    private var hasCallAudioTarget: Bool {
        !captureSystemAudio
            || usesAllSystemAudio
            || applications.contains { $0.bundleID == selectedApplicationBundleID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Prepare your meeting")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("meeting-prepare-title")
                Text("Confirm what Zerm will capture and where transcription will run before recording starts.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Capture") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Microphone — people in the room", isOn: $captureMicrophone)
                        .accessibilityIdentifier("meeting-capture-microphone")
                    Toggle("Call audio — people in the meeting app", isOn: $captureSystemAudio)
                        .accessibilityIdentifier("meeting-capture-call-audio")

                    if captureSystemAudio {
                        Picker("Call audio source", selection: $usesAllSystemAudio) {
                            Text("Selected application").tag(false)
                            Text("All system audio").tag(true)
                        }
                        .help("Choose one running application whenever possible. All system audio can include notifications, music and other applications.")
                        .accessibilityIdentifier("meeting-call-audio-source")

                        if usesAllSystemAudio {
                            Label(
                                "All system audio may include sounds outside the meeting.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("meeting-all-system-warning")
                        } else {
                            HStack {
                                Picker("Meeting application", selection: $selectedApplicationBundleID) {
                                    Text("Choose an application…").tag("")
                                    ForEach(applications) { application in
                                        Text(application.name).tag(application.bundleID)
                                    }
                                }
                                .accessibilityIdentifier("meeting-application-picker")

                                Button(action: refreshApplications) {
                                    Label("Refresh Applications", systemImage: "arrow.clockwise")
                                }
                                .labelStyle(.iconOnly)
                                .help("Refresh the running application list")
                            }

                            Text("For a browser-based meeting, choose the browser that contains the meeting tab.")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Label(
                                "Browser capture may include audio from every tab or helper process owned by that browser, not only the visible meeting tab.",
                                systemImage: "hand.raised.fill"
                            )
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("meeting-browser-privacy-warning")

                            if !hasCallAudioTarget {
                                Label(
                                    "Choose the meeting application or explicitly select All system audio.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.callout)
                                .foregroundStyle(.orange)
                            }
                        }
                    }

                    if !hasSource {
                        Label("Turn on at least one capture source.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }

            GroupBox("Transcript") {
                VStack(alignment: .leading, spacing: 14) {
                    if hasSelectedModel {
                        MeetingConfigurationSummary(
                            modelName: modelName,
                            providerName: providerName,
                            languageName: languageName,
                            languageDisclosure: languageDisclosure,
                            usesCloud: usesCloud
                        )
                    } else {
                        HStack {
                            Label("Choose a Dictation model to transcribe meetings.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Choose Model", action: openModels)
                        }
                    }

                    Divider()
                    Toggle("Show transcript while recording", isOn: $liveTranscript)
                        .accessibilityIdentifier("meeting-live-transcript")
                    Toggle("Identify speakers", isOn: $identifySpeakers)
                        .accessibilityIdentifier("meeting-identify-speakers")
                    Toggle("Create a summary when processing finishes", isOn: $summariseAfterMeeting)
                        .accessibilityIdentifier("meeting-create-summary")

                    if summariseAfterMeeting {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Meeting summary", systemImage: "text.document")
                                .font(.headline)
                            Text("Summary runs separately from Dictation and always uses the selected local Ollama model.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            LabeledContent(
                                "Summary provider",
                                value: "\(summarySnapshot.provider) · \(String(localized: "Local"))"
                            )
                            LabeledContent("Summary model", value: summarySnapshot.model)

                            if isCheckingSummaryAvailability || summaryAvailability == nil {
                                Label("Checking local summary availability…", systemImage: "hourglass")
                                    .foregroundStyle(.secondary)
                            } else if summaryAvailability == true {
                                Label("Local summary model is ready.", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Label(
                                    "Summary will be skipped because Ollama or the selected model is unavailable. Recording and transcription will continue.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.orange)
                                Button("Check Again", action: refreshSummaryAvailability)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button(action: start) {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(
                    !hasSource
                        || !hasCallAudioTarget
                        || ((liveTranscript || summariseAfterMeeting) && !hasSelectedModel)
                        || (summariseAfterMeeting && (isCheckingSummaryAvailability || summaryAvailability == nil))
                )
                .accessibilityIdentifier("meeting-start-recording")
            }
        }
    }
}

struct MeetingLiveView: View {
    let elapsed: TimeInterval
    let capturesMicrophone: Bool
    let capturesSystemAudio: Bool
    let microphoneLevel: Float
    let systemAudioLevel: Float
    let configuration: MeetingConfigurationSummary
    let transcriptItems: [MeetingTranscriptItem]
    let isTranscribing: Bool
    let isPreparingSpeakers: Bool
    let speakerCount: Int
    let sourceHealth: [MeetingAudioSource: MeetingSourceHealth]
    let stop: () -> Void
    let copyTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Recording", systemImage: "record.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(MeetingRecordingView.clock(elapsed))
                            .font(.system(.largeTitle, design: .monospaced).weight(.light))
                            .accessibilityLabel("Elapsed time")
                            .accessibilityValue(Text(MeetingRecordingView.clock(elapsed)))
                    }

                    Spacer()

                    if capturesMicrophone {
                        MeetingLevelMeter(label: String(localized: "Microphone"), decibels: microphoneLevel)
                    }
                    if capturesSystemAudio {
                        MeetingLevelMeter(label: String(localized: "Call audio"), decibels: systemAudioLevel)
                    }

                    Button(action: stop) {
                        Label("Stop Recording", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .accessibilityIdentifier("meeting-stop-recording")
                }

                Divider().padding(.vertical, 8)
                configuration

                if !sourceHealth.isEmpty {
                    Divider().padding(.vertical, 8)
                    MeetingSourceHealthSummary(health: sourceHealth)
                }
            }

            AnalogHeadphoneConfirmationControl()

            MeetingTranscriptPanel(
                items: transcriptItems,
                isWorking: isTranscribing,
                isPreparingSpeakers: isPreparingSpeakers,
                speakerCount: speakerCount,
                emptyMessage: "Listening — transcript lines appear as audio is processed.",
                copyTranscript: copyTranscript
            )
        }
    }
}

struct MeetingProcessingView: View {
    let transcriptItems: [MeetingTranscriptItem]
    let isTranscribing: Bool
    let isSummarising: Bool
    let progress: Double
    let pendingJobs: Int
    let speakerCount: Int
    let copyTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                HStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Finishing your meeting")
                            .font(.headline)
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ProgressView(value: progress)
                    .accessibilityLabel("Meeting processing progress")
                    .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))

                if pendingJobs > 0 {
                    Text("meeting_jobs_remaining \(pendingJobs)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("meeting-processing")

            MeetingTranscriptPanel(
                items: transcriptItems,
                isWorking: true,
                isPreparingSpeakers: false,
                speakerCount: speakerCount,
                emptyMessage: "The transcript is still being prepared.",
                copyTranscript: copyTranscript
            )
        }
    }

    private var statusText: LocalizedStringKey {
        if isTranscribing { return "Completing transcription and speaker alignment…" }
        if isSummarising { return "Creating the meeting summary…" }
        return "Saving the recording…"
    }
}

private struct MeetingSourceHealthSummary: View {
    let health: [MeetingAudioSource: MeetingSourceHealth]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capture health")
                .font(.headline)

            ForEach(MeetingAudioSource.allCases.filter { health[$0] != nil }, id: \.self) { source in
                if let sourceHealth = health[source] {
                    HStack {
                        Label(source.displayName, systemImage: icon(for: sourceHealth.status))
                        Spacer()
                        Text(statusTitle(sourceHealth.status))
                            .foregroundStyle(tint(for: sourceHealth.status))
                        if sourceHealth.droppedFrames > 0 {
                            Text("meeting_dropped_frames \(sourceHealth.droppedFrames)")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)

                    if let message = sourceHealth.message, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func icon(for status: MeetingSourceHealth.Status) -> String {
        switch status {
        case .requested: "hourglass"
        case .capturing: "checkmark.circle.fill"
        case .silent: "speaker.slash"
        case .degraded: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle"
        }
    }

    private func statusTitle(_ status: MeetingSourceHealth.Status) -> LocalizedStringKey {
        switch status {
        case .requested: "Preparing"
        case .capturing: "Capturing"
        case .silent: "Silent"
        case .degraded: "Degraded"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    private func tint(for status: MeetingSourceHealth.Status) -> Color {
        switch status {
        case .capturing: .green
        case .requested, .stopped: .secondary
        case .silent, .degraded: .orange
        case .failed: .red
        }
    }
}

struct MeetingReviewView: View {
    let duration: TimeInterval
    let folderName: String
    let transcriptItems: [MeetingTranscriptItem]
    let speakerCount: Int
    let summary: MeetingSummarizer.Result?
    let summaryError: String?
    let copyTranscript: () -> Void
    let openLibrary: () -> Void
    let showInFinder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Meeting ready")
                            .font(.headline)
                        Text("Saved \(MeetingRecordingView.clock(duration)) to \(folderName)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder", action: showInFinder)
                    Button("Open in Library", action: openLibrary)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if summary != nil || summaryError != nil {
                MeetingSummaryPanel(summary: summary, errorMessage: summaryError)
            }

            MeetingTranscriptPanel(
                items: transcriptItems,
                isWorking: false,
                isPreparingSpeakers: false,
                speakerCount: speakerCount,
                emptyMessage: "No transcript was created for this meeting.",
                copyTranscript: copyTranscript
            )
        }
    }
}

struct MeetingSummaryPanel: View {
    let summary: MeetingSummarizer.Result?
    let errorMessage: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage {
                    Label(
                        "The summary could not be created: \(errorMessage)",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }

                if let summary {
                    if !summary.summary.isEmpty {
                        Text(summary.summary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !summary.actionItems.isEmpty {
                        Text("Actions")
                            .font(.headline)
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: "circle")
                                .labelStyle(.titleAndIcon)
                                .textSelection(.enabled)
                        }
                    }

                    if !summary.chapters.isEmpty {
                        Text("Chapters")
                            .font(.headline)
                        ForEach(Array(summary.chapters.enumerated()), id: \.offset) { _, chapter in
                            LabeledContent(chapter.title, value: MeetingRecordingView.clock(chapter.start))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Summary", systemImage: "sparkles")
                .font(.headline)
        }
    }
}

struct MeetingTranscriptPanel: View {
    let items: [MeetingTranscriptItem]
    let isWorking: Bool
    let isPreparingSpeakers: Bool
    let speakerCount: Int
    let emptyMessage: LocalizedStringKey
    let copyTranscript: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if isWorking { ProgressView().controlSize(.small) }
                    if isPreparingSpeakers {
                        Text("Preparing speaker identification…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if speakerCount > 0 {
                        Label("\(speakerCount) speakers", systemImage: "person.2")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !items.isEmpty {
                        Button("Copy Transcript", action: copyTranscript)
                    }
                }

                if items.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            MeetingTranscriptRow(
                                start: item.start,
                                speaker: item.speaker,
                                text: item.text,
                                isSpeakerEstimated: item.isSpeakerEstimated
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Transcript").font(.headline)
        }
    }
}

struct MeetingNotice: View {
    let message: String
    let icon: String
    let tint: Color
    var primaryAction: (title: LocalizedStringKey, action: () -> Void)?
    var secondaryAction: (title: LocalizedStringKey, action: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let secondaryAction {
                Button(secondaryAction.title, action: secondaryAction.action)
            }
            if let primaryAction {
                Button(primaryAction.title, action: primaryAction.action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct MeetingLevelMeter: View {
    let label: String
    let decibels: Float

    private var fraction: Double {
        min(max(Double((decibels + 60) / 60), 0), 1)
    }

    private var spokenValue: String {
        fraction < 0.05 ? "silent" : "\(Int(fraction * 100)) percent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 90)
                .tint(fraction > 0.9 ? .orange : .accentColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue(spokenValue)
    }
}

#if DEBUG
private struct MeetingPreflightPreview: View {
    @State private var capturesMicrophone = true
    @State private var capturesCall = true
    @State private var allSystemAudio = false
    @State private var liveTranscript = true
    @State private var identifiesSpeakers = true
    @State private var createsSummary = true

    var body: some View {
        ScrollView {
            MeetingPreflightView(
                captureMicrophone: $capturesMicrophone,
                captureSystemAudio: $capturesCall,
                usesAllSystemAudio: $allSystemAudio,
                selectedApplicationBundleID: .constant("com.apple.FaceTime"),
                liveTranscript: $liveTranscript,
                identifySpeakers: $identifiesSpeakers,
                summariseAfterMeeting: $createsSummary,
                applications: [
                    .init(bundleID: "com.apple.FaceTime", name: "FaceTime", processID: 42)
                ],
                modelName: "Whisper Large v3",
                providerName: "Whisper",
                languageName: "Auto-detect",
                languageDisclosure: nil,
                usesCloud: false,
                hasSelectedModel: true,
                summarySnapshot: .configuredOllama,
                summaryAvailability: true,
                isCheckingSummaryAvailability: false,
                start: {},
                openModels: {},
                refreshApplications: {},
                refreshSummaryAvailability: {}
            )
            .padding(24)
        }
        .frame(width: 760, height: 700)
    }
}

#Preview("Meeting preflight") {
    MeetingPreflightPreview()
}

#Preview("Meeting preflight — Hebrew") {
    MeetingPreflightPreview()
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}
#endif
