import SwiftUI

/// The full list of downloadable on-device models. Shared by the AI Enhancement screen and
/// Read Aloud settings so on-device model management looks and behaves the same everywhere.
struct LocalLLMModelListView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(LocalLLMModelManager.packages) { package in
                LocalLLMModelCardView(package: package)
            }
        }
    }
}

/// Management card for a single on-device language model (Gemma). Mirrors the voice/speech
/// model cards: shows size, one-tap download with progress, installed state, delete, and which
/// model is currently in use.
struct LocalLLMModelCardView: View {
    let package: LocalLLMPackage
    @ObservedObject private var manager = LocalLLMModelManager.shared

    private var isCurrent: Bool { manager.currentFileName == package.fileName }
    private var isDownloaded: Bool { manager.isDownloaded(package) }
    private var progress: Double? { manager.downloadProgress[package.fileName] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "brain")
                VStack(alignment: .leading, spacing: 1) {
                    Text(package.displayName).font(.subheadline.weight(.medium))
                    Text("Private, on-device. No API key.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                Text(package.approxSize).font(.caption).foregroundStyle(.secondary)
            }

            if isDownloaded {
                HStack {
                    Label("Downloaded — runs fully offline", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Spacer()
                    if !isCurrent {
                        Button("Use this model") { manager.select(package) }
                            .controlSize(.small)
                    }
                    Button(role: .destructive) { manager.delete(package) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            } else if progress != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress ?? 0)
                    HStack {
                        Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let p = progress {
                            Text("\(Int(p * 100))%").font(.caption.monospacedDigit())
                        }
                        Button("Cancel") { manager.cancelDownload(package) }.controlSize(.small)
                    }
                }
            } else if package.hardwareFit.blocksInstall {
                HardwareFitNotice(fit: package.hardwareFit)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HardwareFitNotice(fit: package.hardwareFit)
                    HStack {
                        Text("Download once to use on-device. No API key needed.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            manager.select(package)
                            Task { await manager.download(package) }
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
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
    }
}
