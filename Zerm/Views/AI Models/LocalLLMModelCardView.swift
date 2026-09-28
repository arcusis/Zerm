import SwiftUI

/// The downloadable on-device models for one job. Enhancement and Read Aloud each keep their own
/// selection; the enhancement list only offers models measured fit for cleanup.
struct LocalLLMModelListView: View {
    var role: LocalLLMRole = .reading
    @ObservedObject private var manager = LocalLLMModelManager.shared

    private var visiblePackages: [LocalLLMPackage] {
        LocalLLMModelManager.packages(for: role)
    }

    private var activePackage: LocalLLMPackage {
        LocalLLMModelManager.package(for: role)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: role.title)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: role.jobDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(manager.isDownloaded(activePackage) ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(manager.isDownloaded(activePackage)
                     ? "In use: \(activePackage.displayName)"
                     : "Download \(activePackage.displayName) to use this job on-device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(visiblePackages) { package in
                LocalLLMModelCardView(package: package, role: role)
            }
        }
    }
}

struct LocalLLMModelCardView: View {
    let package: LocalLLMPackage
    var role: LocalLLMRole = .reading
    @ObservedObject private var manager = LocalLLMModelManager.shared
    @State private var isShowingDownloadNotice = false

    private var isCurrent: Bool {
        switch role {
        case .reading: return manager.currentFileName == package.fileName
        case .enhancement: return manager.enhancementFileName == package.fileName
        }
    }
    private var isDownloaded: Bool { manager.isDownloaded(package) }
    private var progress: Double? { manager.downloadProgress[package.fileName] }
    private var downloadPhase: ModelDownloadPhase? { manager.downloadStates[package.fileName]?.phase }
    private var isRecommended: Bool {
        switch role {
        case .reading:
            return package.fileName == LocalLLMModelManager.recommendedPackage.fileName
        case .enhancement:
            return package.fileName == LocalLLMModelManager.enhancementDefaultPackage.fileName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: role == .enhancement ? "wand.and.stars" : "text.bubble")
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: package.displayName).font(.subheadline.weight(.medium))
                    Text(verbatim: package.blurb)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isCurrent {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                if isRecommended {
                    Label(
                        role == .enhancement ? String(localized: "Enhancement default") : String(localized: "Read Aloud default"),
                        systemImage: "memorychip"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: package.approxSize).font(.caption).foregroundStyle(.secondary)
            }

            if isDownloaded {
                HStack {
                    Label("Downloaded — runs fully offline", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Spacer()
                    if !isCurrent {
                        Button("Use for \(role.title)") { manager.select(package, role: role) }
                            .controlSize(.small)
                    }
                    Button(role: .destructive) { manager.delete(package) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            } else if downloadPhase == .paused {
                HStack {
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "\(Int((manager.downloadStates[package.fileName]?.fractionCompleted ?? 0) * 100))%")
                        .font(.caption.monospacedDigit())
                    if let state = manager.downloadStates[package.fileName], let bytes = state.bytesDownloaded {
                        let formatter = ByteCountFormatter()
                        Text(state.totalBytes.map { "\(formatter.string(fromByteCount: bytes)) / \(formatter.string(fromByteCount: $0))" } ?? formatter.string(fromByteCount: bytes))
                            .font(.caption.monospacedDigit())
                    }
                    Spacer()
                    Button("Resume") { manager.resumeDownload(package) }.controlSize(.small)
                    Button("Cancel") { manager.cancelDownload(package) }.controlSize(.small)
                }
            } else if progress != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress ?? 0)
                    HStack {
                        Text(downloadPhase == .resuming ? "Resuming…" : "Downloading…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let p = progress {
                            Text(verbatim: "\(Int(p * 100))%").font(.caption.monospacedDigit())
                        }
                        if let state = manager.downloadStates[package.fileName], let bytes = state.bytesDownloaded {
                            let formatter = ByteCountFormatter()
                            Text(state.totalBytes.map { "\(formatter.string(fromByteCount: bytes)) / \(formatter.string(fromByteCount: $0))" } ?? formatter.string(fromByteCount: bytes))
                                .font(.caption.monospacedDigit())
                        }
                        Button("Pause") { manager.pauseDownload(package) }.controlSize(.small)
                        Button("Cancel") { manager.cancelDownload(package) }.controlSize(.small)
                    }
                }
            } else if package.hardwareFit.blocksInstall {
                HardwareFitNotice(fit: package.hardwareFit)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HardwareFitNotice(fit: package.hardwareFit)
                    HStack {
                        Text("Download once. No API key.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: requestDownload) {
                            Label(manager.statusText == nil ? "Download" : "Retry Download", systemImage: "arrow.down.circle")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isCurrent ? 0.07 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
        )
        .sheet(isPresented: $isShowingDownloadNotice) {
            ModelDownloadNoticeView(assetID: package.fileName, modelName: package.displayName, provenance: package.provenance) {
                Task { await manager.download(package) }
            }
        }
    }

    private func requestDownload() {
        manager.select(package, role: role)
        if ModelDownloadNoticePolicy.requiresNotice(assetID: package.fileName, provenance: package.provenance) {
            isShowingDownloadNotice = true
        } else {
            Task { await manager.download(package) }
        }
    }
}
