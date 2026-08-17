import SwiftUI

/// The downloadable on-device models for one job. Enhancement and Read Aloud
/// do not share a catalog — Gemma 4 is a Read Aloud model and will introduce
/// itself if asked to clean a transcript.
struct LocalLLMModelListView: View {
    var role: LocalLLMRole = .reading
    @ObservedObject private var manager = LocalLLMModelManager.shared

    private var visiblePackages: [LocalLLMPackage] {
        LocalLLMModelManager.packages(for: role)
    }

    private var activePackage: LocalLLMPackage {
        LocalLLMModelManager.package(for: role)
    }

    private var activeIsOffCatalog: Bool {
        !activePackage.jobs.contains(role)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(role.title)
                    .font(.subheadline.weight(.semibold))
                Text(role.jobDescription)
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

            if activeIsOffCatalog {
                Label(
                    "Using \(activePackage.displayName) until you download an enhancement model. Gemma will introduce itself instead of cleaning the line.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
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

    private var isCurrent: Bool {
        switch role {
        case .reading: return manager.currentFileName == package.fileName
        case .enhancement: return manager.enhancementFileName == package.fileName
        }
    }
    private var isDownloaded: Bool { manager.isDownloaded(package) }
    private var progress: Double? { manager.downloadProgress[package.fileName] }
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
                    Text(package.displayName).font(.subheadline.weight(.medium))
                    Text(package.blurb)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isCurrent {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                if isRecommended {
                    Label(role == .enhancement ? "Instant default" : "Read Aloud default", systemImage: "memorychip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(package.approxSize).font(.caption).foregroundStyle(.secondary)
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
                        Text("Download once. No API key.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            manager.select(package, role: role)
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
