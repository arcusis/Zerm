import SwiftUI
import AppKit

// MARK: - Custom Model Card View
struct CustomModelCardView: View {
    let model: CustomCloudModel
    let isCurrent: Bool
    var setDefaultAction: () -> Void
    var deleteAction: () -> Void
    var editAction: (CustomCloudModel) -> Void

    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @State private var isVerifying = false
    @State private var verificationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main card content
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    headerSection
                    metadataSection
                    descriptionSection
                    verificationSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                actionSection
            }
            .padding(16)
        }
        .background(CardBackground(isSelected: isCurrent, useAccentGradientWhenSelected: isCurrent))
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
            // Provider
            Label("Custom Provider", systemImage: "cloud")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // Language
            Label(model.language, systemImage: "globe")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)

            // OpenAI Compatible
            Label("OpenAI Compatible", systemImage: "checkmark.seal")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabelColor))
                .lineLimit(1)
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

    @ViewBuilder
    private var verificationSection: some View {
        if let verificationError {
            Label(verificationError, systemImage: "exclamationmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundColor(Color(.systemRed))
                .fixedSize(horizontal: false, vertical: true)
        } else if model.verificationStatus == .failed {
            Label("Verification failed. Edit or verify the endpoint before using this model.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(Color(.systemOrange))
        } else if model.verificationStatus == .unverified {
            Label("Not verified yet. Verify the endpoint before using this model.", systemImage: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundColor(Color(.secondaryLabelColor))
        }
    }

    private var actionSection: some View {
        HStack(spacing: 8) {
            if isCurrent {
                Text("Default Model")
                    .font(.system(size: 12))
                    .foregroundColor(Color(.secondaryLabelColor))
            } else if model.isUsable {
                Button(action: setDefaultAction) {
                    Text("Set as Default")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isVerifying {
                ProgressView()
                    .controlSize(.small)
            }

            Menu {
                Button {
                    verify()
                } label: {
                    Label("Verify Endpoint", systemImage: "checkmark.shield")
                }
                .disabled(isVerifying)

                Button {
                    editAction(model)
                } label: {
                    Label("Edit Model", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    deleteAction()
                } label: {
                    Label("Delete Model", systemImage: "trash")
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

    private func verify() {
        isVerifying = true
        verificationError = nil
        Task { @MainActor in
            var succeeded = true
            do {
                try await OpenAICompatibleTranscriptionService().verify(
                    endpoint: model.apiEndpoint,
                    apiKey: model.apiKey,
                    modelName: model.modelName,
                    isMultilingual: model.isMultilingualModel,
                    language: LanguagePreference.apiLanguage()
                )
            } catch {
                succeeded = false
                verificationError = error.localizedDescription
            }
            isVerifying = false
            CustomCloudModelManager.shared.recordVerification(forModelId: model.id, succeeded: succeeded)
            if !succeeded && isCurrent {
                transcriptionModelManager.clearCurrentTranscriptionModel()
            }
            transcriptionModelManager.refreshAllAvailableModels()
        }
    }
}
