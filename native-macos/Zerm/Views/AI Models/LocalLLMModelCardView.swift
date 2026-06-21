import SwiftUI

/// Reusable management card for Zerm's on-device language model (Gemma). Mirrors the voice
/// model cards: shows size, a one-tap download with progress, installed state, and delete.
/// Shared by the AI Models / Enhancement screen and Read Aloud settings so model management
/// looks and behaves the same everywhere.
struct LocalLLMModelCardView: View {
    @ObservedObject private var manager = LocalLLMModelManager.shared

    var body: some View {
        let pkg = LocalLLMModelManager.package
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "brain")
                VStack(alignment: .leading, spacing: 1) {
                    Text(pkg.displayName).font(.subheadline.weight(.medium))
                    Text("Private, on-device. No API key. Recommended.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(pkg.approxSize).font(.caption).foregroundStyle(.secondary)
            }

            if manager.isInstalled {
                HStack {
                    Label("Downloaded — runs fully offline", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Spacer()
                    Button(role: .destructive) { manager.delete() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            } else if manager.isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: manager.downloadProgress ?? 0)
                    HStack {
                        Text(manager.statusText ?? "Downloading…")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let p = manager.downloadProgress {
                            Text("\(Int(p * 100))%").font(.caption.monospacedDigit())
                        }
                        Button("Cancel") { manager.cancelDownload() }.controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Text("Download once to enable on-device AI. No API key needed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await manager.download() } } label: {
                        Label("Download model", systemImage: "arrow.down.circle")
                    }
                    .controlSize(.small)
                }
                if let status = manager.statusText {
                    Text(status).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}
