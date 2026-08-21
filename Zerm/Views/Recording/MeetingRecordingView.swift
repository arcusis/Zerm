import SwiftUI
import UniformTypeIdentifiers

/// The Meetings workspace: prepare, record, process, review and return to the library without
/// mixing configuration controls into the live transcript.
struct MeetingRecordingView: View {
    @EnvironmentObject private var controller: MeetingRecordingController
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var applicationSource = MeetingCaptureApplicationSource()
    @StateObject private var store = MeetingRecordingStore()

    @AppStorage("meetingCaptureMicrophone") private var captureMicrophone = true
    @AppStorage("meetingCaptureSystemAudio") private var captureSystemAudio = true
    @AppStorage("meetingCaptureTargetMode") private var captureTargetMode = "detectedApplication"
    @AppStorage("meetingCaptureApplicationBundleID") private var selectedApplicationBundleID = ""
    @AppStorage("meetingIdentifySpeakers") private var identifySpeakers = true
    @AppStorage("meetingSummarise") private var summariseAfterMeeting = true
    @AppStorage("ollamaSelectedModel") private var ollamaSummaryModel = "mistral"
    @AppStorage("SelectedLanguage") private var selectedLanguage = "auto"

    @State private var importError: String?
    @State private var isFinishing = false
    @State private var isShowingRecordChooser = false
    @State private var pendingSource: MeetingRecordingSourceSelection = .room
    @State private var selectedRecording: MeetingRecordingStore.Item?
    @State private var isCheckingSummaryAvailability = false

    enum Destination {
        case meeting
        case library
    }

    private let destination: Destination

    init(initialDestination: Destination = .meeting) {
        destination = initialDestination
    }

    private enum WorkspacePhase {
        case preflight
        case live
        case processing
        case review
    }

    private var phase: WorkspacePhase {
        if isFinishing || controller.isSummarising { return .processing }
        switch controller.lifecycle.phase {
        case .capturing:
            return .live
        case .stopping, .processing:
            return .processing
        case .ready, .partial:
            return controller.lastRecording == nil ? .preflight : .review
        case .idle, .preflighting, .failed:
            return controller.lastRecording == nil ? .preflight : .review
        }
    }

    private var selectedModel: (any TranscriptionModel)? {
        transcriptionModelManager.currentTranscriptionModel
    }

    private var modelName: String {
        controller.transcriptionSnapshot?.modelDisplayName
            ?? selectedModel?.displayName
            ?? String(localized: "No model selected")
    }

    private var providerName: String {
        controller.transcriptionSnapshot?.provider.rawValue
            ?? selectedModel?.provider.rawValue
            ?? String(localized: "Dictation")
    }

    private var languagePresentation: MeetingLanguagePresentation.Result {
        guard let provider = controller.transcriptionSnapshot?.provider ?? selectedModel?.provider else {
            return .init(
                code: selectedLanguage,
                displayName: String(localized: "Not selected"),
                disclosure: nil
            )
        }
        let code = controller.transcriptionSnapshot?.languageCode ?? selectedLanguage
        let languages = provider == .nativeApple
            ? LanguageDictionary.appleNative
            : selectedModel?.supportedLanguages ?? [:]
        return MeetingLanguagePresentation.resolve(
            provider: provider,
            requestedCode: code,
            supportedLanguages: languages
        )
    }

    private var languageName: String { languagePresentation.displayName }

    private var usesCloudModel: Bool {
        if let snapshot = controller.transcriptionSnapshot {
            return snapshot.route == .cloud
        }
        guard let provider = selectedModel?.provider else { return false }
        switch provider {
        case .whisper, .fluidAudio, .nativeApple:
            return false
        default:
            return true
        }
    }

    private var usesAllSystemAudio: Binding<Bool> {
        Binding(
            get: { captureTargetMode == "allSystemAudio" },
            set: { captureTargetMode = $0 ? "allSystemAudio" : "detectedApplication" }
        )
    }

    private var selectedCaptureApplication: MeetingCaptureApplicationSource.Application? {
        applicationSource.applications.first { $0.bundleID == selectedApplicationBundleID }
    }

    private var configurationSummary: MeetingConfigurationSummary {
        MeetingConfigurationSummary(
            modelName: modelName,
            providerName: providerName,
            languageName: languageName,
            languageDisclosure: languagePresentation.disclosure,
            usesCloud: usesCloudModel
        )
    }

    private var transcriptItems: [MeetingTranscriptItem] {
        controller.segments.map { segment in
            MeetingTranscriptItem(
                id: segment.id,
                start: segment.start,
                speaker: controller.speakerLabel(for: segment),
                isSpeakerEstimated: segment.speakerConfidence == .estimatedFromWindow,
                text: segment.text
            )
        }
    }

    var body: some View {
        Group {
            if destination == .library {
                library
            } else {
                workspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $isShowingRecordChooser) {
            MeetingRecordSourceSheet(
                selection: $pendingSource,
                applications: applicationSource.applications,
                modelName: modelName,
                languageName: languageName,
                hasSelectedModel: selectedModel != nil,
                refreshApplications: applicationSource.refresh,
                openModels: {
                    isShowingRecordChooser = false
                    openDictationModels()
                },
                start: startRecordingFromChooser,
                cancel: { isShowingRecordChooser = false }
            )
        }
        .task {
            store.reload()
            applicationSource.start()
        }
        .task(id: summaryAvailabilityCheckID) {
            guard phase == .preflight, summariseAfterMeeting else { return }
            isCheckingSummaryAvailability = true
            _ = await controller.checkLocalSummaryAvailability()
            isCheckingSummaryAvailability = false
        }
        .onDisappear {
            applicationSource.stop()
        }
    }

    @ViewBuilder
    private var workspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                notices

                switch phase {
                case .preflight:
                    MeetingPreflightView(
                        captureMicrophone: $captureMicrophone,
                        captureSystemAudio: $captureSystemAudio,
                        usesAllSystemAudio: usesAllSystemAudio,
                        selectedApplicationBundleID: $selectedApplicationBundleID,
                        identifySpeakers: $identifySpeakers,
                        summariseAfterMeeting: $summariseAfterMeeting,
                        applications: applicationSource.applications,
                        modelName: modelName,
                        providerName: providerName,
                        languageName: languageName,
                        languageDisclosure: languagePresentation.disclosure,
                        usesCloud: usesCloudModel,
                        hasSelectedModel: selectedModel != nil,
                        summarySnapshot: controller.summarySnapshot ?? .configuredOllama,
                        summaryAvailability: controller.isLocalSummaryAvailable,
                        isCheckingSummaryAvailability: isCheckingSummaryAvailability,
                        start: presentRecordChooser,
                        openModels: openDictationModels,
                        refreshApplications: applicationSource.refresh,
                        refreshSummaryAvailability: refreshSummaryAvailability
                    )
                case .live:
                    MeetingLiveView(
                        elapsed: controller.session.elapsed,
                        capturesMicrophone: captureMicrophone,
                        capturesSystemAudio: captureSystemAudio,
                        microphoneLevel: controller.session.microphoneLevelDb,
                        systemAudioLevel: controller.session.systemAudioLevelDb,
                        configuration: configurationSummary,
                        sourceHealth: controller.sourceHealth,
                        stop: stopRecording
                    )
                case .processing:
                    MeetingProcessingView(
                        transcriptItems: transcriptItems,
                        isTranscribing: controller.isTranscribing,
                        isSummarising: controller.isSummarising,
                        progress: controller.processingProgress,
                        pendingJobs: controller.lifecycle.pendingJobs,
                        speakerCount: controller.speakerCount,
                        copyTranscript: copyTranscript
                    )
                case .review:
                    review
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var notices: some View {
        ForEach(controller.lifecycle.issues) { issue in
            MeetingNotice(
                message: issue.message,
                icon: issue.severity == .error
                    ? "xmark.octagon.fill"
                    : "exclamationmark.triangle.fill",
                tint: issue.severity == .error ? .red : .orange
            )
        }

        if let importError {
            MeetingNotice(
                message: importError,
                icon: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }

        if let message = controller.errorMessage {
            MeetingNotice(
                message: message,
                icon: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }

        if controller.session.systemAudioSilent {
            MeetingNotice(
                message: String(localized: "No call audio is arriving. Check Audio Recording permission before continuing."),
                icon: "speaker.slash.fill",
                tint: .orange,
                primaryAction: ("Open System Settings", openAudioCaptureSettings)
            )
        }

    }

    @ViewBuilder
    private var review: some View {
        if let recording = controller.lastRecording {
            MeetingReviewView(
                duration: recording.duration,
                folderName: recording.folder.lastPathComponent,
                transcriptItems: transcriptItems,
                speakerCount: controller.speakerCount,
                summary: controller.summary,
                summaryError: controller.summaryError,
                copyTranscript: copyTranscript,
                openLibrary: openLastRecording,
                showInFinder: {
                    NSWorkspace.shared.activateFileViewerSelecting([recording.folder])
                }
            )
        }
    }

    @ViewBuilder
    private var library: some View {
        if let selectedRecording {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        self.selectedRecording = nil
                    } label: {
                        Label("All Meetings", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                Divider()

                ScrollView {
                    MeetingDetailView(
                        item: selectedRecording,
                        sidecar: store.readSidecar(in: selectedRecording.folder),
                        onProcessed: { refreshSelectedRecording(folder: selectedRecording.folder) }
                    )
                    .padding(24)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            MeetingLibraryView(
                store: store,
                onOpen: { selectedRecording = $0 },
                onImport: importRecording
            )
        }
    }

    private func startRecording() {
        var sources: MeetingRecordingSession.Sources = []
        if captureMicrophone { sources.insert(.microphone) }
        if captureSystemAudio { sources.insert(.systemAudio) }

        let target: MeetingCaptureTarget
        if captureSystemAudio, captureTargetMode != "allSystemAudio" {
            guard let selectedCaptureApplication else { return }
            target = selectedCaptureApplication.captureTarget
        } else {
            target = .allSystemAudio
        }

        controller.start(request: MeetingRecordingRequest(
            sources: sources,
            target: target,
            identifySpeakers: identifySpeakers
        ))
    }

    private func presentRecordChooser() {
        applicationSource.refresh()

        if captureSystemAudio, captureTargetMode == "allSystemAudio" {
            pendingSource = .allSystemAudio
        } else if captureSystemAudio,
                  let selectedCaptureApplication {
            pendingSource = .application(selectedCaptureApplication.bundleID)
        } else if let recommended = applicationSource.recommendedApplication {
            pendingSource = .application(recommended.bundleID)
        } else {
            pendingSource = .room
        }
        isShowingRecordChooser = true
    }

    private func startRecordingFromChooser() {
        switch pendingSource {
        case .room:
            captureMicrophone = true
            captureSystemAudio = false
            captureTargetMode = "detectedApplication"
        case .application(let bundleID):
            captureMicrophone = true
            captureSystemAudio = true
            captureTargetMode = "detectedApplication"
            selectedApplicationBundleID = bundleID
        case .allSystemAudio:
            captureMicrophone = true
            captureSystemAudio = true
            captureTargetMode = "allSystemAudio"
        }

        isShowingRecordChooser = false
        startRecording()
    }

    private func stopRecording() {
        guard !isFinishing else { return }
        isFinishing = true
        Task {
            await controller.stopAndSummarise(
                ifRequested: summariseAfterMeeting && controller.isLocalSummaryAvailable == true
            )
            store.reload()
            isFinishing = false
        }
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.transcript, forType: .string)
    }

    private var summaryAvailabilityCheckID: String {
        "\(phase == .preflight)-\(summariseAfterMeeting)-\(ollamaSummaryModel)"
    }

    private func refreshSummaryAvailability() {
        Task {
            isCheckingSummaryAvailability = true
            _ = await controller.checkLocalSummaryAvailability()
            isCheckingSummaryAvailability = false
        }
    }

    private func openLastRecording() {
        store.reload()
        NotificationCenter.default.post(
            name: .navigateToDestination,
            object: nil,
            userInfo: ["route": AppRoute.meetingsHistory]
        )
    }

    private func refreshSelectedRecording(folder: URL) {
        store.reload()
        selectedRecording = store.items.first { $0.folder == folder }
    }

    private func openDictationModels() {
        NotificationCenter.default.post(
            name: .navigateToDestination,
            object: nil,
            userInfo: ["route": AppRoute.dictationModels]
        )
    }

    private func importRecording() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MeetingRecordingStore.importableExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose recordings to add to your Meetings library"

        guard panel.runModal() == .OK else { return }
        importError = nil

        for url in panel.urls {
            do {
                _ = try store.importRecording(from: url)
            } catch {
                importError = error.localizedDescription
            }
        }

        store.reload()
        if importError == nil {
            selectedRecording = nil
        }
    }

    private func openAudioCaptureSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
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
