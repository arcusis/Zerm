import SwiftUI

struct ModelDownloadNoticeRequest: Identifiable {
    let id = UUID()
    let assetID: String
    let modelName: String
    let provenance: ModelProvenance
    let onDownload: () -> Void
}

struct ModelDownloadNoticeView: View {
    let assetID: String
    let modelName: String
    let provenance: ModelProvenance
    let onDownload: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var agreed = false

    private var requiresAgreement: Bool {
        ModelDownloadPolicy.requiresExplicitAgreement(assetID: assetID)
    }

    private var hasParakeetVAD: Bool { assetID.hasPrefix("parakeet-") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Third-Party Model Notice").font(.title2.weight(.semibold))
            LabeledContent("Model", value: modelName)
            LabeledContent("Creator", value: provenance.creator)
            LabeledContent("Source") {
                Link(provenance.sourceURL.absoluteString, destination: provenance.sourceURL)
                    .lineLimit(2)
            }
            LabeledContent("License") {
                Link(provenance.licenseName, destination: provenance.licenseURL)
            }
            LabeledContent("Required attribution") {
                Text(LocalizedStringKey(provenance.attribution))
            }
            Text("This model is made by a third party and downloaded from its official source. Zerm does not own it and is not responsible for it.")
                .fixedSize(horizontal: false, vertical: true)
            if requiresAgreement {
                Toggle("I agree to the model license terms.", isOn: $agreed)
            }
            if hasParakeetVAD {
                LabeledContent("Additional download") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Silero VAD by Silero Team")
                        Link("MIT License", destination: URL(string: "https://opensource.org/license/mit")!)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Download") {
                    ModelDownloadAcceptanceStore().accept(
                        assetID: assetID,
                        licenseVersion: ModelDownloadNoticePolicy.acceptanceVersion(for: provenance)
                    )
                    onDownload()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ModelDownloadNoticePolicy.canDownload(assetID: assetID, provenance: provenance, agreed: agreed))
            }
        }
        .padding(24)
        .frame(minWidth: 460, idealWidth: 520)
    }
}

enum ModelDownloadNoticePolicy {
    static func acceptanceVersion(for provenance: ModelProvenance) -> String {
        provenance.sourceURL.absoluteString + "|" + ModelDownloadPolicy.licenseVersion(for: provenance)
    }

    static func requiresNotice(assetID: String, provenance: ModelProvenance) -> Bool {
        !ModelDownloadAcceptanceStore().hasAccepted(assetID: assetID, licenseVersion: acceptanceVersion(for: provenance))
    }

    static func canDownload(assetID: String, provenance: ModelProvenance, agreed: Bool) -> Bool {
        !ModelDownloadPolicy.requiresExplicitAgreement(assetID: assetID) || agreed
    }
}
