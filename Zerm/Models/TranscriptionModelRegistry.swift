import Foundation

enum TranscriptionModelRegistry {

    static var models: [any TranscriptionModel] {
        return predefinedModels + CustomCloudModelManager.shared.customModels
    }

    private static let predefinedModels: [any TranscriptionModel] = {
        let nonCloudModels: [any TranscriptionModel] = [
            NativeAppleModel(
                name: "apple-speech",
                displayName: "Apple Speech",
                description: String(localized: "Uses the native Apple Speech framework for transcription. Requires macOS 26"),
                isMultilingualModel: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .nativeApple),
                provenance: ModelProvenance(
                    creator: "Apple",
                    sourceURL: url("https://developer.apple.com/documentation/speech"),
                    downloadHost: "developer.apple.com",
                    licenseName: "Apple Speech terms",
                    licenseSPDX: "LicenseRef-Apple-Speech-Framework",
                    licenseURL: url("https://www.apple.com/legal/internet-services/terms/site.html"),
                    attribution: "Apple Speech framework; platform-provided model.",
                    conversionCredit: "No model file distributed by Zerm.",
                    checksumSHA256: nil
                )
            ),
            sherpaModel(
                name: "sherpa-moonshine-tiny-en", displayName: "Moonshine Tiny EN",
                description: "A compact English speech model by Useful Sensors, converted to ONNX by sherpa-onnx",
                size: "103 MB", speed: 0.95, accuracy: 0.82, ram: 0.35,
                languages: Languages.english, multilingual: false, family: .moonshine,
                archiveName: "sherpa-onnx-moonshine-tiny-en-int8.tar.bz2",
                checksum: "d5fe6ec4334fef36255b2a4010412cad4c007e33103fec62fb5d17cad88086f2",
                creator: "Useful Sensors", source: "https://huggingface.co/usefulsensors/moonshine-tiny",
                license: "MIT", licenseSPDX: "MIT",
                attribution: "Moonshine Tiny by Useful Sensors. Converted to ONNX by k2-fsa sherpa-onnx."
            ),
            sherpaModel(
                name: "sherpa-moonshine-base-en", displayName: "Moonshine Base EN",
                description: "An English speech model by Useful Sensors, converted to ONNX by sherpa-onnx",
                size: "239 MB", speed: 0.88, accuracy: 0.88, ram: 0.65,
                languages: Languages.english, multilingual: false, family: .moonshine,
                archiveName: "sherpa-onnx-moonshine-base-en-int8.tar.bz2",
                checksum: "21870cecaa2e44e4e2bf63e02d1072bed183ccd10284871353bd9d24dad14e5e",
                creator: "Useful Sensors", source: "https://huggingface.co/usefulsensors/moonshine-base",
                license: "MIT", licenseSPDX: "MIT",
                attribution: "Moonshine Base by Useful Sensors. Converted to ONNX by k2-fsa sherpa-onnx."
            ),
            sherpaModel(
                name: "sherpa-zipformer-ru-vosk-int8", displayName: "Zipformer Russian",
                description: "An offline Russian speech model derived from Vosk and converted to ONNX by sherpa-onnx",
                size: "58 MB", speed: 0.85, accuracy: 0.82, ram: 1.1,
                languages: ["auto": "Auto-detect", "ru": "Russian"], multilingual: false, family: .transducer,
                archiveName: "sherpa-onnx-zipformer-ru-int8-2025-04-20.tar.bz2",
                checksum: "d6a651569aacc9a177259fa54705dd76acae23f6a4d62ea6797bd220d4b57163",
                creator: "Alpha Cephei (Vosk)", source: "https://huggingface.co/alphacep/vosk-model-ru",
                license: "Apache-2.0", licenseSPDX: "Apache-2.0",
                attribution: "Vosk Russian model by Alpha Cephei, converted to Zipformer ONNX by k2-fsa sherpa-onnx."
            ),
            fluidAudioModel(
                name: "parakeet-unified-en-0.6b", displayName: "Parakeet Unified", size: "614 MB",
                description: "NVIDIA's newest English model: the most accurate English transcription on this list, with punctuation and capitalization. Apple Silicon only",
                speed: 0.99, accuracy: 0.98, ram: 0.8, languages: Languages.english,
                sourceRepo: "FluidInference/parakeet-unified-en-0.6b-coreml",
                creator: "NVIDIA NeMo", attribution: "Parakeet Unified English 0.6B by NVIDIA NeMo, CC-BY-4.0."
            ),
            fluidAudioModel(
                name: "parakeet-tdt-ctc-110m", displayName: "Parakeet 110M", size: "228 MB",
                description: "A small, very fast English model that leaves memory free on 8 GB Macs. Apple Silicon only",
                speed: 1.0, accuracy: 0.92, ram: 0.4, languages: Languages.english,
                sourceRepo: "FluidInference/parakeet-tdt-ctc-110m-coreml",
                creator: "NVIDIA NeMo", attribution: "Parakeet TDT-CTC 110M by NVIDIA NeMo, CC-BY-4.0."
            ),
            fluidAudioModel(
                name: "parakeet-tdt-0.6b-v2", displayName: "Parakeet TDT v2", size: "1.2 GB",
                description: "NVIDIA Parakeet TDT v2: accurate English transcription with punctuation and capitalization. Apple Silicon only",
                speed: 0.99, accuracy: 0.98, ram: 1.2, languages: Languages.english,
                sourceRepo: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
                creator: "NVIDIA NeMo", attribution: "Parakeet TDT v2 0.6B by NVIDIA NeMo, CC-BY-4.0."
            ),
            fluidAudioModel(
                name: "parakeet-tdt-0.6b-ultra", displayName: "Parakeet Ultra", size: "595 MB",
                description: "A post-trained Parakeet V3 with the same languages and speed and lower error rates in every published benchmark, especially outside English. Apple Silicon only",
                speed: 0.99, accuracy: 0.96, ram: 0.8, streaming: true, languages: Languages.parakeetEuropean,
                sourceRepo: "FluidInference/parakeet-ultra-coreml",
                creator: "Moondream", attribution: "Parakeet Ultra by Moondream, post-trained from NVIDIA Parakeet TDT 0.6B v3, converted by FluidInference, CC-BY-4.0."
            ),
            fluidAudioModel(
                name: "parakeet-tdt-0.6b-redux", displayName: "Parakeet Redux", size: "220 MB",
                description: "A compact Parakeet model for English and 25 European languages. Requires macOS 15 or later. Apple Silicon only",
                speed: 0.99, accuracy: 0.93, ram: 0.5, streaming: true, minimumMacOS: 15, languages: Languages.parakeetEuropean,
                sourceRepo: "FluidInference/parakeet-redux-coreml",
                creator: "Moondream", attribution: "Parakeet Redux by Moondream, based on NVIDIA Parakeet, converted by FluidInference, CC-BY-4.0."
            ),
            fluidAudioModel(
                name: "parakeet-tdt-0.6b-v3", displayName: "Parakeet V3", size: "494 MB",
                description: "NVIDIA's Parakeet V3 model with multilingual support across English and 25 European languages",
                speed: 0.99, accuracy: 0.94, ram: 0.8, streaming: true, languages: Languages.parakeetEuropean,
                sourceRepo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                creator: "NVIDIA NeMo", attribution: "Parakeet TDT v3 0.6B by NVIDIA NeMo, converted by FluidInference, CC-BY-4.0."
            ),
            whisperModel("ggml-tiny", title: "Whisper Tiny", fileSize: "75 MB", accuracy: 0.56, speed: 1.0, ram: 0.3),
            whisperModel("ggml-tiny.en", title: "Whisper Tiny English", fileSize: "75 MB", englishOnly: true, accuracy: 0.58, speed: 1.0, ram: 0.3),
            whisperModel("ggml-base", title: "Whisper Base", fileSize: "142 MB", accuracy: 0.66, speed: 0.95, ram: 0.4),
            whisperModel("ggml-base.en", title: "Whisper Base English", fileSize: "142 MB", englishOnly: true, accuracy: 0.68, speed: 0.95, ram: 0.4),
            whisperModel("ggml-small", title: "Whisper Small", fileSize: "466 MB", accuracy: 0.78, speed: 0.85, ram: 0.7),
            whisperModel("ggml-small.en", title: "Whisper Small English", fileSize: "466 MB", englishOnly: true, accuracy: 0.80, speed: 0.85, ram: 0.7),
            whisperModel("ggml-medium", title: "Whisper Medium", fileSize: "1.5 GB", accuracy: 0.87, speed: 0.7, ram: 1.2),
            whisperModel("ggml-medium.en", title: "Whisper Medium English", fileSize: "1.5 GB", englishOnly: true, accuracy: 0.89, speed: 0.7, ram: 1.2),
            whisperModel("ggml-large-v2", title: "Whisper Large v2", fileSize: "3.1 GB", accuracy: 0.92, speed: 0.55, ram: 1.95),
            whisperModel("ggml-large-v2-q5_0", title: "Whisper Large v2 Q5_0", fileSize: "1.1 GB", accuracy: 0.90, speed: 0.65, ram: 1.15, quantized: true),
            whisperModel("ggml-large-v2-q8_0", title: "Whisper Large v2 Q8_0", fileSize: "1.7 GB", accuracy: 0.91, speed: 0.6, ram: 1.5, quantized: true),
            whisperModel("ggml-large-v3", title: "Whisper Large v3", fileSize: "3.1 GB", accuracy: 0.94, speed: 0.55, ram: 1.95),
            whisperModel("ggml-large-v3-q5_0", title: "Whisper Large v3 Q5_0", fileSize: "1.1 GB", accuracy: 0.92, speed: 0.65, ram: 1.15, quantized: true),
            whisperModel("ggml-large-v3-turbo", title: "Large v3 Turbo", fileSize: "1.6 GB", accuracy: 0.97, speed: 0.75, ram: 1.8),
            whisperModel("ggml-large-v3-turbo-q5_0", title: "Large v3 Turbo Q5_0", fileSize: "574 MB", accuracy: 0.95, speed: 0.75, ram: 1.0, quantized: true),
            whisperModel("ggml-large-v3-turbo-q8_0", title: "Large v3 Turbo Q8_0", fileSize: "874 MB", accuracy: 0.96, speed: 0.75, ram: 1.35, quantized: true),
            whisperModel("ggml-medium-q5_0", title: "Whisper Medium Q5_0", fileSize: "539 MB", accuracy: 0.85, speed: 0.75, ram: 0.95, quantized: true),
            whisperModel("ggml-medium-q8_0", title: "Whisper Medium Q8_0", fileSize: "823 MB", accuracy: 0.86, speed: 0.72, ram: 1.15, quantized: true),
            whisperModel("ggml-medium.en-q5_0", title: "Whisper Medium English Q5_0", fileSize: "539 MB", englishOnly: true, accuracy: 0.87, speed: 0.75, ram: 0.95, quantized: true),
            whisperModel("ggml-medium.en-q8_0", title: "Whisper Medium English Q8_0", fileSize: "823 MB", englishOnly: true, accuracy: 0.88, speed: 0.72, ram: 1.15, quantized: true),
            whisperModel("ggml-tiny-q8_0", title: "Whisper Tiny Q8_0", fileSize: "44 MB", accuracy: 0.55, speed: 1.0, ram: 0.25, quantized: true),
            whisperModel("ggml-tiny.en-q8_0", title: "Whisper Tiny English Q8_0", fileSize: "44 MB", englishOnly: true, accuracy: 0.57, speed: 1.0, ram: 0.25, quantized: true),
            whisperModel("ggml-base-q8_0", title: "Whisper Base Q8_0", fileSize: "82 MB", accuracy: 0.65, speed: 0.97, ram: 0.3, quantized: true),
            whisperModel("ggml-base.en-q8_0", title: "Whisper Base English Q8_0", fileSize: "82 MB", englishOnly: true, accuracy: 0.67, speed: 0.97, ram: 0.3, quantized: true),
            whisperModel("ggml-small-q8_0", title: "Whisper Small Q8_0", fileSize: "264 MB", accuracy: 0.77, speed: 0.88, ram: 0.55, quantized: true),
            whisperModel("ggml-small.en-q8_0", title: "Whisper Small English Q8_0", fileSize: "264 MB", englishOnly: true, accuracy: 0.79, speed: 0.88, ram: 0.55, quantized: true),
            whisperModel("ggml-distil-large-v3", title: "Distil-Whisper Large v3", fileSize: "1.5 GB", englishOnly: true, accuracy: 0.91, speed: 0.82, ram: 1.1, distil: true),
            WhisperModel(
                name: "ivrit-large-v3-turbo", displayName: "ivrit.ai Large v3 Turbo", size: "1.6 GB",
                supportedLanguages: hebrewFineTuneLanguages,
                description: String(localized: "Whisper Large v3 Turbo fine-tuned on Hebrew speech by ivrit.ai. Transcribes in Hebrew unless you choose English"),
                speed: 0.75, accuracy: 0.96, ramUsage: 1.8, isHebrewOptimized: true,
                source: ModelIntegrity.ivritLargeV3Turbo,
                provenance: ivritProvenance(source: ModelIntegrity.ivritLargeV3Turbo, card: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml", sha: ModelIntegrity.whisperSHA256["ivrit-large-v3-turbo"]!)
            ),
            WhisperModel(
                name: "ivrit-large-v3", displayName: "ivrit.ai Large v3", size: "3.1 GB",
                supportedLanguages: hebrewFineTuneLanguages,
                description: String(localized: "The most accurate Hebrew model, fine-tuned by ivrit.ai. Slower and needs a Mac with 24 GB of memory or more"),
                speed: 0.5, accuracy: 0.97, ramUsage: 3.1, isHebrewOptimized: true,
                source: ModelIntegrity.ivritLargeV3,
                provenance: ivritProvenance(source: ModelIntegrity.ivritLargeV3, card: "https://huggingface.co/ivrit-ai/whisper-large-v3-ggml", sha: ModelIntegrity.whisperSHA256["ivrit-large-v3"]!)
            )
        ]

        let cloudModels: [any TranscriptionModel] = CloudProviderRegistry.allProviders.flatMap { $0.models }
        return nonCloudModels + cloudModels
    }()

    private enum Languages {
        static let english = ["en": "English"]
        static let parakeetEuropean = LanguageDictionary.forProvider(isMultilingual: true, provider: .fluidAudio)
    }

    private static func url(_ value: String) -> URL { URL(string: value)! }

    private static func fluidAudioModel(
        name: String, displayName: String, size: String, description: String,
        speed: Double, accuracy: Double, ram: Double, streaming: Bool = false,
        minimumMacOS: Int? = nil, languages: [String: String], sourceRepo: String,
        creator: String, attribution: String
    ) -> FluidAudioModel {
        return FluidAudioModel(
            name: name, displayName: displayName, description: String(localized: String.LocalizationValue(description)),
            size: size, speed: speed, accuracy: accuracy, ramUsage: ram, supportsStreaming: streaming,
            minimumMacOSMajorVersion: minimumMacOS, supportedLanguages: languages,
            provenance: ModelProvenance(
                creator: creator,
                sourceURL: url("https://huggingface.co/\(sourceRepo)"),
                downloadHost: "huggingface.co",
                licenseName: "CC-BY-4.0",
                licenseSPDX: "CC-BY-4.0",
                licenseURL: url("https://creativecommons.org/licenses/by/4.0/"),
                attribution: attribution,
                conversionCredit: "Core ML conversion and packaging by FluidInference.",
                checksumSHA256: ModelIntegrity.fluidAudioSHA256[name]
            )
        )
    }

    private static func sherpaModel(
        name: String, displayName: String, description: String, size: String,
        speed: Double, accuracy: Double, ram: Double, languages: [String: String], multilingual: Bool,
        family: SherpaOnnxModelFamily, archiveName: String, checksum: String,
        creator: String, source: String, license: String, licenseSPDX: String,
        attribution: String
    ) -> SherpaOnnxModel {
        SherpaOnnxModel(
            name: name, displayName: displayName, description: String(localized: String.LocalizationValue(description)),
            size: size, speed: speed, accuracy: accuracy, estimatedRAMGB: ram,
            isMultilingualModel: multilingual, supportedLanguages: languages,
            family: family, archiveName: archiveName, sha256: checksum,
            provenance: ModelProvenance(
                creator: creator, sourceURL: url(source), downloadHost: "github.com",
                licenseName: license, licenseSPDX: licenseSPDX,
                licenseURL: url(license == "MIT" ? "https://opensource.org/license/mit/" : "https://www.apache.org/licenses/LICENSE-2.0"),
                attribution: attribution, conversionCredit: "k2-fsa sherpa-onnx",
                checksumSHA256: checksum
            )
        )
    }

    private static func whisperModel(
        _ name: String, title: String, fileSize: String, englishOnly: Bool = false,
        accuracy: Double, speed: Double, ram: Double, quantized: Bool = false, distil: Bool = false
    ) -> WhisperModel {
        let source: ModelIntegrity.PinnedFile = distil
            ? ModelIntegrity.distilLargeV3
            : .whisperCpp(fileName: "\(name).bin")
        let sha = ModelIntegrity.whisperSHA256[name]!
        let card = distil
            ? "https://huggingface.co/distil-whisper/distil-large-v3"
            : "https://github.com/openai/whisper/blob/main/model-card.md"
        return WhisperModel(
            name: name, displayName: title, size: fileSize,
            supportedLanguages: englishOnly ? Languages.english : LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper),
            description: whisperDescription(distil: distil, quantized: quantized),
            speed: speed, accuracy: accuracy, ramUsage: ram,
            source: source,
            provenance: ModelProvenance(
                creator: distil ? "Hugging Face Distil-Whisper and OpenAI" : "OpenAI",
                sourceURL: url(card),
                downloadHost: URL(string: source.downloadURL)?.host ?? "huggingface.co",
                licenseName: "MIT",
                licenseSPDX: "MIT",
                licenseURL: url("https://opensource.org/license/mit/"),
                attribution: distil
                    ? "Distil-Whisper large-v3 by Hugging Face, based on OpenAI Whisper; MIT License."
                    : "Whisper by OpenAI; include OpenAI's MIT copyright and license notice.",
                conversionCredit: whisperConversionCredit(distil: distil, quantized: quantized),
                checksumSHA256: sha
            )
        )
    }

    private static func whisperDescription(distil: Bool, quantized: Bool) -> String {
        if distil { return String(localized: "English-only Distil-Whisper large-v3 converted to ggml for whisper.cpp") }
        if quantized { return String(localized: "Quantized OpenAI Whisper model converted and published by ggml-org") }
        return String(localized: "OpenAI Whisper model converted to ggml and published by ggml-org")
    }

    private static func whisperConversionCredit(distil: Bool, quantized: Bool) -> String {
        if distil { return "Official ggml conversion by Distil-Whisper maintainers." }
        if quantized { return "Quantized and converted by ggml-org." }
        return "Converted and published by ggml-org."
    }

    private static func ivritProvenance(source: ModelIntegrity.PinnedFile, card: String, sha: String) -> ModelProvenance {
        return ModelProvenance(
            creator: "ivrit.ai",
            sourceURL: url(card),
            downloadHost: URL(string: source.downloadURL)?.host ?? "huggingface.co",
            licenseName: "Apache-2.0",
            licenseSPDX: "Apache-2.0",
            licenseURL: url("https://www.apache.org/licenses/LICENSE-2.0"),
            attribution: "ivrit.ai Whisper fine-tune; Apache-2.0. Preserve license and notices.",
            conversionCredit: "Fine-tuned and converted to ggml by ivrit.ai.",
            checksumSHA256: sha
        )
    }

    /// ivrit.ai fine-tunes are tuned for Hebrew and keep English words; other languages are not offered.
    private static let hebrewFineTuneLanguages = LanguageDictionary.all.filter { ["auto", "he", "en"].contains($0.key) }
}
