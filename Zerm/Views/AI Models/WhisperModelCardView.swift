import SwiftUI
import AppKit
// MARK: - Local Model Card View
struct WhisperModelCardView: View {
    let model: WhisperModel
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
    @State private var isShowingDownloadNotice = false
    private var isDownloading: Bool {
        downloadProgress.keys.contains(model.name + "_main") || 
        downloadProgress.keys.contains(model.name + "_coreml")
    }

    private var downloadButtonTitle: LocalizedStringKey {
        if isDownloading { return "Downloading..." }
        if downloadError != nil { return "Retry Download" }
        return "Download"
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Main Content
            VStack(alignment: .leading, spacing: 6) {
                headerSection
                metadataSection
                ModelBadgesRow(model: model)
                descriptionSection
                if let provenance = model.provenance {
                    ModelProvenanceDisclosure(provenance: provenance)
                }
                if !isDownloaded {
                    HardwareFitNotice(fit: model.hardwareFit)
                }
                if let downloadError, !isDownloading {
                    DownloadErrorNotice(message: downloadError)
                }
                progressSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Action Controls
            actionSection
        }
        .padding(16)
        .background(CardBackground(isSelected: isCurrent, useAccentGradientWhenSelected: isCurrent))
        .sheet(isPresented: $isShowingDownloadNotice) {
            if let provenance = model.provenance {
                ModelDownloadNoticeView(assetID: model.name, modelName: model.displayName, provenance: provenance) {
                    downloadAction()
                }
            }
        }
    }
    
    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: model.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(.labelColor))
            
            Spacer()
        }
    }
    
    private var metadataSection: some View {
        HStack(spacing: 12) {
            // Language
            Label(model.language, systemImage: "globe")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)
            
            // Size
            Label(model.size, systemImage: "internaldrive")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)
            
            // Speed
            HStack(spacing: 3) {
                Text("Speed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(.secondaryLabelColor))
                progressDotsWithNumber(value: model.speed * 10)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            
            // Accuracy
            HStack(spacing: 3) {
                Text("Accuracy")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(.secondaryLabelColor))
                progressDotsWithNumber(value: model.accuracy * 10)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
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
            if isDownloading || isPaused {
                DownloadProgressView(
                    modelName: model.name,
                    downloadProgress: downloadProgress,
                    downloadState: downloadState
                )
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    private var actionSection: some View {
        HStack(spacing: 8) {
            if isCurrent {
                Text("Default Model")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabelColor))
            } else if isDownloaded {
                if isWarming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Optimizing model for your device...")
                            .font(.system(size: 12))
                            .foregroundColor(Color(.secondaryLabelColor))
                    }
                } else {
                    Button(action: setDefaultAction) {
                        Text("Set as Default")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if model.hardwareFit.blocksInstall {
                Text("Unavailable")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(.tertiaryLabelColor))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(.quaternaryLabelColor).opacity(0.3)))
                    .help("This model needs more memory than this Mac has available")
            } else if isPaused {
                HStack(spacing: 6) {
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                    if let resumeDownloadAction { Button("Resume", action: resumeDownloadAction).controlSize(.small) }
                    if let cancelDownloadAction { Button("Cancel", action: cancelDownloadAction).controlSize(.small) }
                }
            } else if isDownloading, let cancelDownloadAction {
                Button("Pause", action: pauseDownloadAction ?? cancelDownloadAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Cancel", action: cancelDownloadAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(action: requestDownload) {
                    HStack(spacing: 4) {
                        Text(downloadButtonTitle)
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color(.controlAccentColor))
                            .shadow(color: Color(.controlAccentColor).opacity(0.2), radius: 2, x: 0, y: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)
            }
            
            if isDownloaded {
                Menu {
                    Button(action: deleteAction) {
                        Label("Delete Model", systemImage: "trash")
                    }
                    
                    Button {
                        if let modelURL = modelURL {
                            NSWorkspace.shared.selectFile(modelURL.path, inFileViewerRootedAtPath: "")
                        }
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
            downloadAction()
        }
    }
}

struct ModelProvenanceDisclosure: View {
    let provenance: ModelProvenance

    var body: some View {
        DisclosureGroup("Source and license") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text("Creator")
                    Text(verbatim: provenance.creator)
                }
                HStack(spacing: 4) {
                    Link("Model card", destination: provenance.sourceURL)
                    Text(verbatim: provenance.downloadHost)
                }
                HStack(spacing: 4) {
                    Text("License")
                    Text(verbatim: provenance.licenseName)
                    Link("License details", destination: provenance.licenseURL)
                }
                HStack(alignment: .top, spacing: 4) {
                    Text("Required credit")
                    Text(verbatim: provenance.attribution)
                }
                HStack(alignment: .top, spacing: 4) {
                    Text("Conversion")
                    Text(verbatim: provenance.conversionCredit ?? "")
                }
            }
            .font(.system(size: 10))
            .foregroundColor(Color(.secondaryLabelColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Color(.secondaryLabelColor))
    }
}

// MARK: - Imported Local Model (minimal UI)
struct ImportedWhisperModelCardView: View {
    let model: ImportedWhisperModel
    let isDownloaded: Bool
    let isCurrent: Bool
    let modelURL: URL?

    var deleteAction: () -> Void
    var setDefaultAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: model.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(.labelColor))
                    Spacer()
                }

                Text("Imported local model")
                    .font(.system(size: 11))
                    .foregroundColor(Color(.secondaryLabelColor))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if isCurrent {
                    Text("Default Model")
                        .font(.system(size: 12))
                        .foregroundColor(Color(.secondaryLabelColor))
                } else if isDownloaded {
                    Button(action: setDefaultAction) {
                        Text("Set as Default")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if isDownloaded {
                    Menu {
                        Button(action: deleteAction) {
                            Label("Delete Model", systemImage: "trash")
                        }
                        Button {
                            if let modelURL = modelURL {
                                NSWorkspace.shared.selectFile(modelURL.path, inFileViewerRootedAtPath: "")
                            }
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
        .padding(16)
        .background(CardBackground(isSelected: isCurrent, useAccentGradientWhenSelected: isCurrent))
    }
}


// MARK: - Helper Views and Functions

func progressDotsWithNumber(value: Double) -> some View {
    HStack(spacing: 4) {
        progressDots(value: value)
        Text(verbatim: String(format: "%.1f", value))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(Color(.secondaryLabelColor))
    }
}

func progressDots(value: Double) -> some View {
    HStack(spacing: 2) {
        ForEach(0..<5) { index in
            Circle()
                .fill(index < Int(value / 2) ? performanceColor(value: value / 10) : Color(.quaternaryLabelColor))
                .frame(width: 6, height: 6)
        }
    }
}

func performanceColor(value: Double) -> Color {
    switch value {
    case 0.8...1.0: return Color(.systemGreen)
    case 0.6..<0.8: return Color(.systemYellow)
    case 0.4..<0.6: return Color(.systemOrange)
    default: return Color(.systemRed)
    }
}
