import Foundation
import os

class CustomCloudModelManager: ObservableObject {
    static let shared = CustomCloudModelManager()

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "CustomCloudModelManager")
    private let userDefaults = UserDefaults.standard
    private let customModelsKey = "customCloudModels"

    @Published var customModels: [CustomCloudModel] = []

    private init() {
        loadCustomModels()
    }

    // MARK: - CRUD Operations

    func addCustomModel(_ model: CustomCloudModel) {
        customModels.append(model)
        saveCustomModels()
    }

    func removeCustomModel(withId id: UUID) {
        customModels.removeAll { $0.id == id }
        saveCustomModels()
        APIKeyManager.shared.deleteCustomModelAPIKey(forModelId: id)
    }

    func updateCustomModel(_ updatedModel: CustomCloudModel) {
        if let index = customModels.firstIndex(where: { $0.id == updatedModel.id }) {
            customModels[index] = updatedModel
            saveCustomModels()
        }
    }

    /// Persists the outcome of a live verification; a failed endpoint stops being selectable.
    func recordVerification(forModelId id: UUID, succeeded: Bool, at date: Date = Date()) {
        guard let index = customModels.firstIndex(where: { $0.id == id }) else { return }
        customModels[index].verificationStatus = succeeded ? .verified : .failed
        if succeeded {
            customModels[index].lastVerifiedAt = date
        }
        saveCustomModels()
    }

    // MARK: - Persistence

    private func loadCustomModels() {
        guard let data = userDefaults.data(forKey: customModelsKey) else {
            return
        }

        do {
            customModels = try JSONDecoder().decode([CustomCloudModel].self, from: data)
        } catch {
            logger.error("Failed to decode custom models: \(error.localizedDescription, privacy: .public)")
            customModels = []
        }
    }

    func saveCustomModels() {
        do {
            let data = try JSONEncoder().encode(customModels)
            userDefaults.set(data, forKey: customModelsKey)
        } catch {
            logger.error("Failed to encode custom models: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Validation

    func validateModel(name: String, displayName: String, apiEndpoint: String, apiKey: String, modelName: String, excludingId: UUID? = nil) -> [String] {
        Self.validationErrors(
            name: name,
            displayName: displayName,
            apiEndpoint: apiEndpoint,
            apiKey: apiKey,
            modelName: modelName,
            existingModels: customModels.filter { $0.id != excludingId },
            builtInModels: TranscriptionModelRegistry.models.filter { $0.provider != .custom }
        )
    }

    static func validationErrors(
        name: String,
        displayName: String,
        apiEndpoint: String,
        apiKey: String,
        modelName: String,
        existingModels: [CustomCloudModel],
        builtInModels: [any TranscriptionModel]
    ) -> [String] {
        var errors: [String] = []

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "Name cannot be empty"))
        }

        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "Display name cannot be empty"))
        }

        if apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "API endpoint cannot be empty"))
        } else if OpenAICompatibleTranscriptionService.endpointURL(apiEndpoint) == nil {
            errors.append(String(localized: "API endpoint must be a valid http or https URL"))
        }

        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "API key cannot be empty"))
        }

        if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(String(localized: "Model name cannot be empty"))
        }

        // The model name is how Zerm remembers the default model, so it must be unique across
        // built-in and custom models alike.
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if builtInModels.contains(where: { $0.name == name || $0.displayName.lowercased() == normalizedDisplayName }) {
            errors.append(String(localized: "This name is already used by a built-in model"))
        } else if existingModels.contains(where: { $0.name == name }) {
            errors.append(String(localized: "A model with this name already exists"))
        }

        return errors
    }
}

/// A known host that implements OpenAI's transcription endpoint, verified against its docs on
/// 2026-09-13. The user supplies the key.
struct CustomEndpointPreset: Identifiable, Hashable {
    let name: String
    let endpoint: String
    let modelNames: [String]
    let documentationURL: URL

    var id: String { name }

    // Not offered: Fireworks retired audio inference on 2026-06-10, Cloudflare Workers AI has no
    // OpenAI-compatible transcription route, and Lemonfox documents neither a model id nor ISO
    // language codes.
    static let all: [CustomEndpointPreset] = [
        CustomEndpointPreset(
            name: "Together AI",
            endpoint: "https://api.together.ai/v1/audio/transcriptions",
            modelNames: ["openai/whisper-large-v3"],
            documentationURL: URL(string: "https://docs.together.ai/docs/speech-to-text")!
        ),
        CustomEndpointPreset(
            name: "DeepInfra",
            endpoint: "https://api.deepinfra.com/v1/audio/transcriptions",
            modelNames: ["openai/whisper-large-v3-turbo", "openai/whisper-large-v3"],
            documentationURL: URL(string: "https://docs.deepinfra.com/api-reference/audio/openai-audio-transcriptions")!
        ),
        CustomEndpointPreset(
            name: "OpenRouter",
            endpoint: "https://openrouter.ai/api/v1/audio/transcriptions",
            modelNames: ["microsoft/mai-transcribe-2", "openai/whisper-large-v3"],
            documentationURL: URL(string: "https://openrouter.ai/docs/guides/overview/multimodal/stt")!
        )
    ]
}
