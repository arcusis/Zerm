import Foundation

enum TranscriptionModelRegistry {

    static var models: [any TranscriptionModel] {
        return predefinedModels + CustomCloudModelManager.shared.customModels
    }
    
    private static let predefinedModels: [any TranscriptionModel] = {
        let nonCloudModels: [any TranscriptionModel] = [
            // Native Apple Model
            NativeAppleModel(
                name: "apple-speech",
                displayName: "Apple Speech",
                description: "Uses the native Apple Speech framework for transcription. Requires macOS 26",
                isMultilingualModel: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .nativeApple)
            ),

            // Parakeet Models
            FluidAudioModel(
                name: "parakeet-unified-en-0.6b",
                displayName: "Parakeet Unified",
                description: String(localized: "NVIDIA's newest English model: the most accurate English transcription on this list, with punctuation and capitalization. Apple Silicon only"),
                size: "614 MB",
                speed: 0.99,
                accuracy: 0.98,
                ramUsage: 0.8,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "parakeet-tdt-ctc-110m",
                displayName: "Parakeet 110M",
                description: String(localized: "A small, very fast English model that leaves memory free on 8 GB Macs. Apple Silicon only"),
                size: "228 MB",
                speed: 1.0,
                accuracy: 0.92,
                ramUsage: 0.4,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "parakeet-tdt-0.6b-v3",
                displayName: "Parakeet V3",
                description: "NVIDIA's Parakeet V3 model with multilingual support across English and 25 European languages",
                size: "494 MB",
                speed: 0.99,
                accuracy: 0.94,
                ramUsage: 0.8,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .fluidAudio)
            ),

            // Local Models
            WhisperModel(
                name: "ggml-large-v3-turbo",
                displayName: "Large v3 Turbo",
                size: "1.5 GB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Large model v3 Turbo, faster than v3 with similar accuracy",
                speed: 0.75,
                accuracy: 0.97,
                ramUsage: 1.8
            ),
            WhisperModel(
                name: "ggml-large-v3-turbo-q5_0",
                displayName: "Large v3 Turbo (Quantized)",
                size: "547 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: "Quantized version of Large v3 Turbo, faster with slightly lower accuracy",
                speed: 0.75,
                accuracy: 0.95,
                ramUsage: 1.0
            ),

            // Hebrew fine-tunes
            WhisperModel(
                name: "ivrit-large-v3-turbo",
                displayName: "ivrit.ai Large v3 Turbo",
                size: "1.6 GB",
                supportedLanguages: hebrewFineTuneLanguages,
                description: String(localized: "Whisper Large v3 Turbo fine-tuned on Hebrew speech by ivrit.ai. Transcribes in Hebrew unless you choose English"),
                speed: 0.75,
                accuracy: 0.96,
                ramUsage: 1.8,
                isHebrewOptimized: true,
                source: ModelIntegrity.ivritLargeV3Turbo
            ),
            WhisperModel(
                name: "ivrit-large-v3",
                displayName: "ivrit.ai Large v3",
                size: "3.1 GB",
                supportedLanguages: hebrewFineTuneLanguages,
                description: String(localized: "The most accurate Hebrew model, fine-tuned by ivrit.ai. Slower and needs a Mac with 24 GB of memory or more"),
                speed: 0.5,
                accuracy: 0.97,
                ramUsage: 3.1,
                isHebrewOptimized: true,
                source: ModelIntegrity.ivritLargeV3
            )
        ]

        let cloudModels: [any TranscriptionModel] = CloudProviderRegistry.allProviders.flatMap { $0.models }
        return nonCloudModels + cloudModels
    }()

    /// ivrit.ai fine-tunes are tuned for Hebrew and keep English words; other languages are not offered.
    private static let hebrewFineTuneLanguages = LanguageDictionary.all.filter { ["auto", "he", "en"].contains($0.key) }
}
