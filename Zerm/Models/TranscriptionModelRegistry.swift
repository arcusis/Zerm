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
                description: String(localized: "Uses the native Apple Speech framework for transcription. Requires macOS 26"),
                isMultilingualModel: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .nativeApple)
            ),

            SherpaOnnxModel(
                name: "sherpa-moonshine-tiny-en",
                displayName: "Moonshine Tiny EN",
                description: String(localized: "A compact English speech model by Useful Sensors, converted to ONNX by sherpa-onnx"),
                size: "103 MB",
                speed: 0.95,
                accuracy: 0.82,
                estimatedRAMGB: 0.35,
                isMultilingualModel: false,
                supportedLanguages: ["en": "English"],
                family: .moonshine,
                archiveName: "sherpa-onnx-moonshine-tiny-en-int8.tar.bz2",
                sha256: "d5fe6ec4334fef36255b2a4010412cad4c007e33103fec62fb5d17cad88086f2",
                provenance: ModelProvenance(
                    creator: "Useful Sensors",
                    sourceURL: URL(string: "https://huggingface.co/usefulsensors/moonshine-tiny")!,
                    licenseSPDX: "MIT",
                    licenseURL: URL(string: "https://opensource.org/license/mit/")!,
                    attribution: "Moonshine Tiny by Useful Sensors. Converted to ONNX by k2-fsa sherpa-onnx.",
                    converterCredit: "k2-fsa sherpa-onnx"
                )
            ),
            SherpaOnnxModel(
                name: "sherpa-moonshine-base-en",
                displayName: "Moonshine Base EN",
                description: String(localized: "An English speech model by Useful Sensors, converted to ONNX by sherpa-onnx"),
                size: "239 MB",
                speed: 0.88,
                accuracy: 0.88,
                estimatedRAMGB: 0.65,
                isMultilingualModel: false,
                supportedLanguages: ["en": "English"],
                family: .moonshine,
                archiveName: "sherpa-onnx-moonshine-base-en-int8.tar.bz2",
                sha256: "21870cecaa2e44e4e2bf63e02d1072bed183ccd10284871353bd9d24dad14e5e",
                provenance: ModelProvenance(
                    creator: "Useful Sensors",
                    sourceURL: URL(string: "https://huggingface.co/usefulsensors/moonshine-base")!,
                    licenseSPDX: "MIT",
                    licenseURL: URL(string: "https://opensource.org/license/mit/")!,
                    attribution: "Moonshine Base by Useful Sensors. Converted to ONNX by k2-fsa sherpa-onnx.",
                    converterCredit: "k2-fsa sherpa-onnx"
                )
            ),
            SherpaOnnxModel(
                name: "sherpa-zipformer-ru-vosk-int8",
                displayName: "Zipformer Russian",
                description: String(localized: "An offline Russian speech model derived from Vosk and converted to ONNX by sherpa-onnx"),
                size: "58 MB",
                speed: 0.85,
                accuracy: 0.82,
                estimatedRAMGB: 1.1,
                isMultilingualModel: false,
                supportedLanguages: ["auto": "Auto-detect", "ru": "Russian"],
                family: .transducer,
                archiveName: "sherpa-onnx-zipformer-ru-int8-2025-04-20.tar.bz2",
                sha256: "d6a651569aacc9a177259fa54705dd76acae23f6a4d62ea6797bd220d4b57163",
                provenance: ModelProvenance(
                    creator: "Alpha Cephei (Vosk)",
                    sourceURL: URL(string: "https://huggingface.co/alphacep/vosk-model-ru")!,
                    licenseSPDX: "Apache-2.0",
                    licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
                    attribution: "Vosk Russian model by Alpha Cephei, converted to Zipformer ONNX by k2-fsa sherpa-onnx.",
                    converterCredit: "k2-fsa sherpa-onnx"
                )
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
                name: "parakeet-tdt-0.6b-ultra",
                displayName: "Parakeet Ultra",
                description: String(localized: "A post-trained Parakeet V3 with the same languages and speed and lower error rates in every published benchmark, especially outside English. Apple Silicon only"),
                size: "595 MB",
                speed: 0.99,
                accuracy: 0.96,
                ramUsage: 0.8,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "parakeet-tdt-0.6b-v3",
                displayName: "Parakeet V3",
                description: String(localized: "NVIDIA's Parakeet V3 model with multilingual support across English and 25 European languages"),
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
                description: String(localized: "Large model v3 Turbo, faster than v3 with similar accuracy"),
                speed: 0.75,
                accuracy: 0.97,
                ramUsage: 1.8
            ),
            WhisperModel(
                name: "ggml-large-v3-turbo-q5_0",
                displayName: "Large v3 Turbo (Quantized)",
                size: "547 MB",
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
                description: String(localized: "Quantized version of Large v3 Turbo, faster with slightly lower accuracy"),
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
