import SwiftUI

struct AddCustomModelCardView: View {
    @ObservedObject var customModelManager: CustomCloudModelManager
    var onModelAdded: () -> Void
    var editingModel: CustomCloudModel? = nil

    @State private var isExpanded = false
    @State private var displayName = ""
    @State private var apiEndpoint = ""
    @State private var apiKey = ""
    @State private var modelName = ""
    @State private var isMultilingual = true
    @State private var selectedPreset: CustomEndpointPreset?

    @State private var validationErrors: [String] = []
    @State private var showingAlert = false
    @State private var isSaving = false
    @State private var verificationError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Simple Add Model Button
            if !isExpanded {
                Button(action: {
                    withAnimation(.interpolatingSpring(stiffness: 170, damping: 20)) {
                        isExpanded = true
                        // Pre-fill values - either from editing model or defaults
                        if let editing = editingModel {
                            fill(from: editing)
                        } else {
                            // Pre-fill some default values when adding new
                            if apiEndpoint.isEmpty {
                                apiEndpoint = "https://api.example.com/v1/audio/transcriptions"
                            }
                            if modelName.isEmpty {
                                modelName = "large-v3-turbo"
                            }
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                        Text(editingModel != nil ? "Edit Model" : "Add Model")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 8, y: 4)
            }

            // Expandable Form Section
            if isExpanded {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    HStack {
                        Text(editingModel != nil ? "Edit Custom Model" : "Add Custom Model")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Spacer()

                        Button(action: {
                            withAnimation(.interpolatingSpring(stiffness: 170, damping: 20)) {
                                isExpanded = false
                                clearForm()
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    // Disclaimer
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Only OpenAI-compatible transcription APIs are supported. Zerm sends a one-second test recording to verify the endpoint before saving.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)

                    presetSection

                    // Form fields
                    VStack(alignment: .leading, spacing: 16) {
                        FormField(title: "Display Name", text: $displayName, placeholder: "My Custom Model")
                        FormField(title: "API Endpoint", text: $apiEndpoint, placeholder: "https://api.example.com/v1/audio/transcriptions")
                        FormField(title: "API Key", text: $apiKey, placeholder: "your-api-key", isSecure: true)
                        HStack(alignment: .bottom, spacing: 8) {
                            FormField(title: "Model Name", text: $modelName, placeholder: "whisper-1")
                            if let selectedPreset, selectedPreset.modelNames.count > 1 {
                                Menu("Suggested") {
                                    ForEach(selectedPreset.modelNames, id: \.self) { name in
                                        Button(name) { modelName = name }
                                    }
                                }
                                .fixedSize()
                            }
                        }

                        Toggle(isOn: $isMultilingual) {
                            HStack(spacing: 4) {
                                Text("Multilingual Model")
                                InfoTip(String(localized: "Turn on if this endpoint transcribes languages other than English. When on, Zerm offers a language picker and sends the selected language with each request; when off, no language is sent."))
                            }
                        }
                    }

                    if let verificationError {
                        Label(verificationError, systemImage: "exclamationmark.octagon.fill")
                            .font(.caption)
                            .foregroundColor(Color(.systemRed))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        Button(action: {
                            withAnimation(.interpolatingSpring(stiffness: 170, damping: 20)) {
                                isExpanded = false
                                clearForm()
                            }
                        }) {
                            Text("Cancel")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            addModel()
                        }) {
                            HStack(spacing: 6) {
                                if isSaving {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: editingModel != nil ? "checkmark.circle.fill" : "plus.circle.fill")
                                        .font(.system(size: 14))
                                }
                                Text(saveButtonTitle)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isFormValid ? Color(.controlAccentColor) : Color.secondary)
                                    .shadow(color: (isFormValid ? Color(.controlAccentColor) : Color.secondary).opacity(0.2), radius: 2, x: 0, y: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isFormValid || isSaving)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.windowBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.separatorColor), lineWidth: 1)
                        )
                )
            }
        }
        .alert("Validation Errors", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(verbatim: validationErrors.joined(separator: "\n"))
        }
        .onChange(of: editingModel) { oldValue, newValue in
            if newValue != nil {
                withAnimation(.interpolatingSpring(stiffness: 170, damping: 20)) {
                    isExpanded = true
                    // Pre-fill values from editing model
                    if let editing = newValue {
                        fill(from: editing)
                    }
                }
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $selectedPreset) {
                Text("Custom endpoint").tag(CustomEndpointPreset?.none)
                ForEach(CustomEndpointPreset.all) { preset in
                    Text(verbatim: preset.name).tag(Optional(preset))
                }
            } label: {
                Text("Preset")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .pickerStyle(.menu)
            .onChange(of: selectedPreset) { _, preset in
                guard let preset else { return }
                apiEndpoint = preset.endpoint
                modelName = preset.modelNames.first ?? modelName
                if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    displayName = preset.name
                }
                verificationError = nil
            }

            if let selectedPreset {
                Link(destination: selectedPreset.documentationURL) {
                    Label("Get an API key and model list from \(selectedPreset.name)", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
    }

    private var saveButtonTitle: LocalizedStringKey {
        if isSaving { return "Verifying..." }
        return editingModel != nil ? "Verify and Update" : "Verify and Add"
    }

    private var isFormValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func fill(from model: CustomCloudModel) {
        displayName = model.displayName
        apiEndpoint = model.apiEndpoint
        apiKey = model.apiKey
        modelName = model.modelName
        isMultilingual = model.isMultilingualModel
        selectedPreset = nil
        verificationError = nil
    }

    private func clearForm() {
        displayName = ""
        apiEndpoint = ""
        apiKey = ""
        modelName = ""
        isMultilingual = true
        selectedPreset = nil
        verificationError = nil
    }

    private func addModel() {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApiEndpoint = apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Generate a name from display name (lowercase, no spaces)
        let generatedName = trimmedDisplayName.lowercased().replacingOccurrences(of: " ", with: "-")

        validationErrors = customModelManager.validateModel(
            name: generatedName,
            displayName: trimmedDisplayName,
            apiEndpoint: trimmedApiEndpoint,
            apiKey: trimmedApiKey,
            modelName: trimmedModelName,
            excludingId: editingModel?.id
        )

        if !validationErrors.isEmpty {
            showingAlert = true
            return
        }

        isSaving = true
        verificationError = nil
        let multilingual = isMultilingual

        Task { @MainActor in
            do {
                try await OpenAICompatibleTranscriptionService().verify(
                    endpoint: trimmedApiEndpoint,
                    apiKey: trimmedApiKey,
                    modelName: trimmedModelName,
                    isMultilingual: multilingual,
                    language: LanguagePreference.apiLanguage()
                )
            } catch {
                verificationError = error.localizedDescription
                isSaving = false
                return
            }

            let model = CustomCloudModel(
                id: editingModel?.id ?? UUID(),
                name: generatedName,
                displayName: trimmedDisplayName,
                description: String(localized: "Custom transcription model"),
                apiEndpoint: trimmedApiEndpoint,
                modelName: trimmedModelName,
                isMultilingual: multilingual,
                verificationStatus: .verified,
                lastVerifiedAt: Date()
            )

            guard APIKeyManager.shared.saveCustomModelAPIKey(trimmedApiKey, forModelId: model.id) else {
                validationErrors = [String(localized: "Failed to securely save API Key to Keychain. Please check your system settings or try again.")]
                showingAlert = true
                isSaving = false
                return
            }

            if editingModel != nil {
                customModelManager.updateCustomModel(model)
            } else {
                customModelManager.addCustomModel(model)
            }

            onModelAdded()

            withAnimation(.interpolatingSpring(stiffness: 170, damping: 20)) {
                isExpanded = false
                clearForm()
                isSaving = false
            }
        }
    }
}

struct FormField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let placeholder: LocalizedStringKey
    var isSecure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            if isSecure {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
