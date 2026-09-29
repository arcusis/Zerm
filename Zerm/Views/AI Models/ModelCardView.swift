import SwiftUI
import AppKit

enum ModelCatalogStatus: CaseIterable, Equatable {
    case available, downloading, paused, downloaded

    var title: LocalizedStringKey {
        switch self {
        case .available: "Available"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .downloaded: "Downloaded"
        }
    }

    static func resolve(isDownloaded: Bool, isDownloading: Bool, isPaused: Bool) -> ModelCatalogStatus {
        if isPaused { return .paused }
        if isDownloading { return .downloading }
        return isDownloaded ? .downloaded : .available
    }
}

struct ModelCardView: View {
    let model: any TranscriptionModel
    let fluidAudioModelManager: FluidAudioModelManager
    let sherpaOnnxModelManager: SherpaOnnxModelManager
    let transcriptionModelManager: TranscriptionModelManager
    let isDownloaded: Bool
    let isCurrent: Bool
    let downloadProgress: [String: Double]
    let downloadState: ModelDownloadState?
    let modelURL: URL?
    let isWarming: Bool
    let downloadError: String?
    let isPaused: Bool

    // Actions
    var deleteAction: () -> Void
    var setDefaultAction: () -> Void
    var downloadAction: () -> Void
    var cancelDownloadAction: (() -> Void)?
    var pauseDownloadAction: (() -> Void)?
    var resumeDownloadAction: (() -> Void)?
    var editAction: ((CustomCloudModel) -> Void)?
    var body: some View {
        Group {
            switch model.provider {
            case .whisper:
                if let whisperModel = model as? WhisperModel {
                    WhisperModelCardView(
                        model: whisperModel,
                        isDownloaded: isDownloaded,
                        isCurrent: isCurrent,
                        downloadProgress: downloadProgress,
                        downloadState: downloadState,
                        modelURL: modelURL,
                        isWarming: isWarming,
                        downloadError: downloadError,
                        isPaused: isPaused,
                        deleteAction: deleteAction,
                        setDefaultAction: setDefaultAction,
                        downloadAction: downloadAction,
                        cancelDownloadAction: cancelDownloadAction,
                        pauseDownloadAction: pauseDownloadAction,
                        resumeDownloadAction: resumeDownloadAction
                    )
                } else if let importedModel = model as? ImportedWhisperModel {
                    ImportedWhisperModelCardView(
                        model: importedModel,
                        isDownloaded: isDownloaded,
                        isCurrent: isCurrent,
                        modelURL: modelURL,
                        deleteAction: deleteAction,
                        setDefaultAction: setDefaultAction
                    )
                }
            case .fluidAudio:
                if let fluidAudioModel = model as? FluidAudioModel {
                    FluidAudioModelCardView(
                        model: fluidAudioModel,
                        fluidAudioModelManager: fluidAudioModelManager,
                        transcriptionModelManager: transcriptionModelManager
                    )
                }
            case .sherpaOnnx:
                if let sherpaModel = model as? SherpaOnnxModel {
                    SherpaOnnxModelCardView(
                        model: sherpaModel,
                        manager: sherpaOnnxModelManager,
                        isCurrent: isCurrent,
                        deleteAction: deleteAction,
                        setDefaultAction: setDefaultAction
                    )
                }
            case .nativeApple:
                if let nativeAppleModel = model as? NativeAppleModel {
                    NativeAppleModelCardView(
                        model: nativeAppleModel,
                        isCurrent: isCurrent,
                        setDefaultAction: setDefaultAction
                    )
                }
            case .custom:
                if let customModel = model as? CustomCloudModel {
                    CustomModelCardView(
                        model: customModel,
                        isCurrent: isCurrent,
                        setDefaultAction: setDefaultAction,
                        deleteAction: deleteAction,
                        editAction: editAction ?? { _ in }
                    )
                }
            default:
                if let cloudModel = model as? CloudModel {
                    CloudModelCardView(
                        model: cloudModel,
                        isCurrent: isCurrent,
                        setDefaultAction: setDefaultAction
                    )
                }
            }
        }
    }
}

private struct SherpaOnnxModelCardView: View {
    let model: SherpaOnnxModel
    @ObservedObject var manager: SherpaOnnxModelManager
    let isCurrent: Bool
    let deleteAction: () -> Void
    let setDefaultAction: () -> Void
    @State private var isShowingDownloadNotice = false

    private var isDownloaded: Bool { manager.isDownloaded(model) }
    private var isDownloading: Bool { manager.downloadingModels.contains(model.name) }
    private var isPaused: Bool { manager.isPaused(model) }
    private var progressLabel: LocalizedStringKey {
        if isPaused { return "Paused" }
        return manager.downloadStates[model.name]?.phase == .resuming ? "Resuming…" : "Downloading…"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: model.displayName)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 12) {
                    Label(model.language, systemImage: "globe")
                    Label(model.size, systemImage: "internaldrive")
                    Label("sherpa-onnx", systemImage: "cpu")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Text(verbatim: model.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let provenance = model.provenance {
                    ModelProvenanceDisclosure(provenance: provenance)
                }
                if let message = manager.downloadErrors[model.name], !isDownloading {
                    DownloadErrorNotice(message: message)
                }
                if isDownloading || isPaused {
                    ProgressView(value: manager.downloadProgress[model.name] ?? manager.downloadStates[model.name]?.fractionCompleted ?? 0)
                    Text(progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                if isCurrent {
                    Text("Default Model").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if isDownloaded {
                    Button("Set as Default", action: setDefaultAction).controlSize(.small)
                    Button("Delete", action: deleteAction).controlSize(.small)
                } else if isPaused {
                    Button("Resume") { manager.resumeDownload(model) }.controlSize(.small)
                    Button("Cancel") { manager.cancelDownload(model) }.controlSize(.small)
                } else if isDownloading {
                    Button("Pause") { manager.pauseDownload(model) }.controlSize(.small)
                    Button("Cancel") { manager.cancelDownload(model) }.controlSize(.small)
                } else {
                    Button(manager.downloadErrors[model.name] == nil ? "Download" : "Retry Download") {
                        requestDownload()
                    }
                    .controlSize(.small)
                }
            }
            .frame(minWidth: 156, alignment: .trailing)
        }
        .padding(16)
        .background(CardBackground(isSelected: isCurrent, useAccentGradientWhenSelected: isCurrent))
        .sheet(isPresented: $isShowingDownloadNotice) {
            if let provenance = model.provenance {
                ModelDownloadNoticeView(assetID: model.name, modelName: model.displayName, provenance: provenance) {
                    manager.startDownload(model)
                }
            }
        }
    }

    private func requestDownload() {
        guard let provenance = model.provenance else { return }
        if ModelDownloadNoticePolicy.requiresNotice(assetID: model.name, provenance: provenance) {
            isShowingDownloadNotice = true
        } else {
            manager.startDownload(model)
        }
    }
}
