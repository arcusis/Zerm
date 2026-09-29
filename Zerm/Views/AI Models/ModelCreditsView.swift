import SwiftUI

private struct ModelCredit: Identifiable {
    let id: String
    let name: String
    let provenance: ModelProvenance
}

struct ModelCreditsView: View {
    @EnvironmentObject private var whisperManager: WhisperModelManager
    @EnvironmentObject private var fluidManager: FluidAudioModelManager
    @EnvironmentObject private var sherpaOnnxManager: SherpaOnnxModelManager
    @ObservedObject private var llmManager = LocalLLMModelManager.shared
    @ObservedObject private var kokoroManager = KokoroModelManager.shared
    @ObservedObject private var blueManager = BlueModelManager.shared

    private var credits: [ModelCredit] {
        var entries: [ModelCredit] = []
        for model in TranscriptionModelRegistry.models {
            guard let provenance = model.provenance else { continue }
            let downloaded: Bool
            switch model.provider {
            case .whisper:
                downloaded = whisperManager.availableModels.contains { $0.name == model.name }
            case .fluidAudio:
                downloaded = fluidManager.isFluidAudioModelDownloaded(named: model.name)
            case .sherpaOnnx:
                guard let sherpa = model as? SherpaOnnxModel else { continue }
                downloaded = sherpaOnnxManager.isDownloaded(sherpa)
            default:
                downloaded = false
            }
            if downloaded { entries.append(ModelCredit(id: model.name, name: model.displayName, provenance: provenance)) }
        }
        for package in LocalLLMModelManager.packages where llmManager.isDownloaded(package) {
            entries.append(ModelCredit(id: package.fileName, name: package.displayName, provenance: package.provenance))
        }
        if kokoroManager.isInstalled {
            let package = KokoroModelManager.package
            entries.append(ModelCredit(id: package.name, name: package.displayName, provenance: package.provenance))
        }
        if blueManager.isInstalled {
            entries.append(ModelCredit(
                id: BlueModelManager.packageName,
                name: BlueModelManager.displayName,
                provenance: BlueModelCatalog.provenance
            ))
        }
        if TranscriptionModelRegistry.models.contains(where: {
            $0.provider == .fluidAudio && fluidManager.isFluidAudioModelDownloaded(named: $0.name)
        }) {
            let vad = ModelProvenance(
                creator: "Silero Team",
                sourceURL: URL(string: "https://huggingface.co/FluidInference/silero-vad-coreml")!,
                downloadHost: "huggingface.co",
                licenseName: "MIT",
                licenseSPDX: "MIT",
                licenseURL: URL(string: "https://opensource.org/license/mit")!,
                attribution: "Silero VAD by Silero Team; CoreML conversion by FluidAudio.",
                conversionCredit: "FluidAudio",
                checksumSHA256: nil
            )
            entries.append(ModelCredit(id: "silero-vad-coreml", name: "Silero VAD", provenance: vad))
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model credits").font(.title2.weight(.semibold))
            if credits.isEmpty {
                Text("Downloaded model attributions will appear here.")
                    .foregroundStyle(.secondary)
            } else {
                List(credits) { credit in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: credit.name).font(.headline)
                        Text(LocalizedStringKey(credit.provenance.attribution))
                        Text("Creator: \(credit.provenance.creator)").font(.caption)
                        HStack {
                            Link("Source", destination: credit.provenance.sourceURL)
                            Link(credit.provenance.licenseName, destination: credit.provenance.licenseURL)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
    }
}
