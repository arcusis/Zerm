import SwiftUI
import UniformTypeIdentifiers

/// Drop audio or video files, choose how they are transcribed, and follow them through the queue.
struct TranscribeFileView: View {
    @EnvironmentObject private var queue: FileTranscriptionQueue
    @State private var isDropTargeted = false
    @State private var isChoosingFiles = false
    @State private var openJobID: UUID?

    var body: some View {
        Group {
            if let job = queue.jobs.first(where: { $0.id == openJobID }), let transcript = job.transcript {
                FileTranscriptView(jobID: job.id, transcript: transcript) { openJobID = nil }
            } else {
                queuePage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            add(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(
            isPresented: $isChoosingFiles,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { add(urls) }
        }
    }

    private func add(_ urls: [URL]) {
        openJobID = nil
        queue.add(urls)
    }

    private var queuePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcribe File")
                        .font(.largeTitle.bold())
                    Text("Drop a recording to get its full transcript, with each speaker identified.")
                        .foregroundStyle(.secondary)
                }

                dropZone
                FileTranscriptionOptionsView()

                if !queue.jobs.isEmpty {
                    jobList
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
            Text("Drop audio or video files here")
                .font(.headline)
            Button("Choose Files…") { isChoosingFiles = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
            Text("MP3, M4A, WAV, FLAC, MP4, MOV and other audio or video files")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .accessibilityIdentifier("transcribe-file-drop-zone")
    }

    private var jobList: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(queue.jobs) { job in
                    FileTranscriptionJobRow(job: job) { openJobID = job.id }
                    if job.id != queue.jobs.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 8)
        } label: {
            HStack {
                Text("Files")
                    .font(.headline)
                Spacer()
                if queue.hasFinishedJobs {
                    Button("Clear Finished") { queue.clearFinished() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

/// One file in the queue: its progress, the options it runs with, and what can be done with it.
private struct FileTranscriptionJobRow: View {
    @EnvironmentObject private var queue: FileTranscriptionQueue
    @EnvironmentObject private var modelManager: TranscriptionModelManager

    let job: FileTranscriptionQueue.Job
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: job.fileName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
                Text(verbatim: summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
            actions
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if job.state == .completed { onOpen() }
        }
    }

    @ViewBuilder
    private var status: some View {
        if job.isCancelling {
            Text("Cancelling…")
                .foregroundStyle(.secondary)
        } else {
            switch job.state {
            case .queued:
                Text("Waiting")
                    .foregroundStyle(.secondary)
            case .converting:
                progress("Preparing audio…", value: nil)
            case .transcribing(let value):
                progress("Transcribing…", value: value)
            case .diarizing(let value):
                progress("Identifying speakers…", value: value > 0 ? value : nil)
            case .completed:
                if job.transcript?.speakerStatus == .failed {
                    Label("Completed without speakers", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("Completed")
                        .foregroundStyle(.secondary)
                }
            case .failed(let error):
                Text(verbatim: error.message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .cancelled:
                Text("Cancelled")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func progress(_ title: LocalizedStringKey, value: Double?) -> some View {
        HStack(spacing: 8) {
            if let value {
                ProgressView(value: value)
                    .frame(maxWidth: 200)
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch job.state {
            case .queued, .converting, .transcribing, .diarizing:
                Button("Cancel") { queue.cancel(job.id) }
                    .disabled(job.isCancelling)
            case .completed:
                Button("View Transcript", action: onOpen)
                    .buttonStyle(.borderedProminent)
                removeButton
            case .failed(let error):
                if error != .unsupportedFile {
                    Button("Retry") { queue.retry(job.id) }
                }
                removeButton
            case .cancelled:
                Button("Retry") { queue.retry(job.id) }
                removeButton
            }
        }
    }

    private var removeButton: some View {
        Button {
            queue.remove(job.id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove from list")
        .accessibilityLabel("Remove from list")
    }

    private var icon: String {
        switch job.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "stop.circle"
        case .queued: "clock"
        case .converting, .transcribing, .diarizing: "waveform"
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var summary: String {
        let options = job.options
        let model = modelManager.allAvailableModels.first { $0.name == options.modelName }
        var parts = [options.modelDisplayName]
        if let model {
            parts.append(FileTranscriptionOptionsView.languageName(options.languageCode, for: model))
        }
        if options.identifySpeakers {
            switch options.speakerCount {
            case .automatic: parts.append(String(localized: "Speakers detected automatically"))
            case .fixed(let count): parts.append(String(localized: "file_transcription_speakers \(count)"))
            }
        } else {
            parts.append(String(localized: "No speaker labels"))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
