import SwiftUI
import Combine
import AppKit

struct FluidAudioModelCardView: View {
    let model: FluidAudioModel
    @ObservedObject var fluidAudioModelManager: FluidAudioModelManager
    @ObservedObject var transcriptionModelManager: TranscriptionModelManager
    @State private var streamingEnabled: Bool
    @State private var isShowingDownloadNotice = false

    init(model: FluidAudioModel, fluidAudioModelManager: FluidAudioModelManager, transcriptionModelManager: TranscriptionModelManager) {
        self.model = model
        _fluidAudioModelManager = ObservedObject(wrappedValue: fluidAudioModelManager)
        _transcriptionModelManager = ObservedObject(wrappedValue: transcriptionModelManager)
        let key = "streaming-enabled-\(model.name)"
        _streamingEnabled = State(initialValue: UserDefaults.standard.object(forKey: key) as? Bool ?? true)
    }

    private var streamingDefaultsKey: String {
        "streaming-enabled-\(model.name)"
    }

    private var downloadButtonTitle: LocalizedStringKey {
        if isDownloading { return "Downloading..." }
        if fluidAudioModelManager.downloadErrors[model.name] != nil { return "Retry Download" }
        return "Download"
    }

    var isCurrent: Bool {
        transcriptionModelManager.currentTranscriptionModel?.name == model.name
    }

    var isDownloaded: Bool {
        fluidAudioModelManager.isFluidAudioModelDownloaded(model)
    }

    var isDownloading: Bool {
        fluidAudioModelManager.isFluidAudioModelDownloading(model)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                headerSection
                metadataSection
                descriptionSection
                if model.minimumMacOSMajorVersion != nil {
                    Label("Requires macOS 15+", systemImage: "info.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(.secondaryLabelColor))
                }
                if let provenance = model.provenance {
                    ModelProvenanceDisclosure(provenance: provenance)
                }
                if !isDownloaded {
                    HardwareFitNotice(fit: model.hardwareFit)
                }
                if let downloadError = fluidAudioModelManager.downloadErrors[model.name], !isDownloading {
                    DownloadErrorNotice(message: downloadError)
                }
                progressSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actionSection
        }
        .padding(16)
        .background(CardBackground(isSelected: isCurrent, useAccentGradientWhenSelected: isCurrent))
        .sheet(isPresented: $isShowingDownloadNotice) {
            if let provenance = model.provenance {
                ModelDownloadNoticeView(assetID: model.name, modelName: model.displayName, provenance: provenance) {
                    startDownload()
                }
            }
        }
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: model.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(.labelColor))

            if model.supportsStreaming && isDownloaded {
                Toggle("Real-time", isOn: $streamingEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(.secondaryLabelColor))
                    .onChange(of: streamingEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: streamingDefaultsKey)
                    }
                    .help(streamingEnabled ? "Live streaming enabled — click to switch to batch" : "Batch mode — click to enable live streaming")

                InfoTip(
                    String(localized: "On, the model transcribes as you speak and the text appears in the recorder live. Off, it waits for the full recording, which tends to read better on long dictations because it has the whole sentence to work with."),
                    doc: .models
                )
            }

            Spacer()
        }
    }

    private var metadataSection: some View {
        HStack(spacing: 12) {
            Label(model.language, systemImage: "globe")
            Label(model.size, systemImage: "internaldrive")
            HStack(spacing: 3) {
                Text("Speed")
                progressDotsWithNumber(value: model.speed * 10)
            }
            .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 3) {
                Text("Accuracy")
                progressDotsWithNumber(value: model.accuracy * 10)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 11))
        .foregroundColor(Color(.secondaryLabelColor))
        .lineLimit(1)
    }

    private var descriptionSection: some View {
        Text(verbatim: model.description)
            .font(.system(size: 11))
            .foregroundColor(Color(.secondaryLabelColor))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    private var progressSection: some View {
        Group {
            if isDownloading || fluidAudioModelManager.isPaused(model) {
                let progress = fluidAudioModelManager.downloadProgress[model.name] ?? fluidAudioModelManager.downloadStates[model.name]?.fractionCompleted ?? 0.0
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle())
                    HStack {
                        Text(fluidAudioModelManager.downloadStates[model.name]?.phase == .resuming ? "Resuming…" : "Downloading…")
                        Spacer()
                        Text(verbatim: "\(Int(progress * 100))%")
                        Text("Byte count unavailable")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: 8) {
            if !FluidAudioModelManager.isModelAvailable(model.name) {
                Text("Requires macOS 15 or later")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(.secondaryLabelColor))
            } else if isCurrent {
                Text("Default Model")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabelColor))
            } else if isDownloaded {
                Button(action: {
                    Task {
                        transcriptionModelManager.setDefaultTranscriptionModel(model)
                    }
                }) {
                    Text("Set as Default")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.hardwareFit.blocksInstall {
                Text("Unavailable")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(.tertiaryLabelColor))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(.quaternaryLabelColor).opacity(0.3)))
                    .help("This model needs more memory than this Mac has available")
            } else if fluidAudioModelManager.isPaused(model) {
                HStack(spacing: 6) {
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                    Button("Resume") { fluidAudioModelManager.resumeDownload(model) }.controlSize(.small)
                    Text("FluidAudio resumes saved partial files when retried.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Cancel") { fluidAudioModelManager.cancelDownload(model) }.controlSize(.small)
                }
            } else if isDownloading {
                HStack(spacing: 6) {
                    Button("Pause") { fluidAudioModelManager.pauseDownload(model) }.controlSize(.small)
                    Button("Cancel") { fluidAudioModelManager.cancelDownload(model) }.controlSize(.small)
                }
            } else {
                Button(action: requestDownload) {
                    HStack(spacing: 4) {
                        Text(downloadButtonTitle)
                        Image(systemName: "arrow.down.circle")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)
            }

            if isDownloaded {
                Menu {
                    Button(action: {
                        fluidAudioModelManager.deleteFluidAudioModel(model)
                    }) {
                        Label("Delete Model", systemImage: "trash")
                    }

                    Button {
                        fluidAudioModelManager.showFluidAudioModelInFinder(model)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }

                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: 20)
            }
        }
    }

    private func requestDownload() {
        guard let provenance = model.provenance else { return }
        if ModelDownloadNoticePolicy.requiresNotice(assetID: model.name, provenance: provenance) {
            isShowingDownloadNotice = true
        } else {
            startDownload()
        }
    }

    private func startDownload() {
        fluidAudioModelManager.startDownload(model)
    }
}
