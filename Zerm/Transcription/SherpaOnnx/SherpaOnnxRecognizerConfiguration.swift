import Foundation

struct SherpaOnnxRecognizerFiles: Equatable {
    let tokens: URL
    let preprocessor: URL?
    let encoder: URL
    let uncachedDecoder: URL?
    let cachedDecoder: URL?
    let decoder: URL?
    let joiner: URL?
    let bpeVocabulary: URL?

    var requiredFiles: [URL] {
        [tokens, preprocessor, encoder, uncachedDecoder, cachedDecoder, decoder, joiner, bpeVocabulary].compactMap { $0 }
    }
}

enum SherpaOnnxRecognizerConfiguration {
    static func files(for model: SherpaOnnxModel, in directory: URL) -> SherpaOnnxRecognizerFiles {
        switch model.family {
        case .moonshine:
            return SherpaOnnxRecognizerFiles(
                tokens: directory.appendingPathComponent("tokens.txt"),
                preprocessor: directory.appendingPathComponent("preprocess.onnx"),
                encoder: directory.appendingPathComponent("encode.int8.onnx"),
                uncachedDecoder: directory.appendingPathComponent("uncached_decode.int8.onnx"),
                cachedDecoder: directory.appendingPathComponent("cached_decode.int8.onnx"),
                decoder: nil,
                joiner: nil,
                bpeVocabulary: nil
            )
        case .transducer:
            return SherpaOnnxRecognizerFiles(
                tokens: directory.appendingPathComponent("tokens.txt"),
                preprocessor: nil,
                encoder: directory.appendingPathComponent("encoder.int8.onnx"),
                uncachedDecoder: nil,
                cachedDecoder: nil,
                decoder: directory.appendingPathComponent("decoder.onnx"),
                joiner: directory.appendingPathComponent("joiner.int8.onnx"),
                bpeVocabulary: directory.appendingPathComponent("bpe.model")
            )
        }
    }

    static func makeConfig(
        for model: SherpaOnnxModel,
        in directory: URL,
        numThreads: Int = HardwareCapability.inferenceThreadCount
    ) -> SherpaOnnxOfflineRecognizerConfig {
        let files = files(for: model, in: directory)
        let modelConfig: SherpaOnnxOfflineModelConfig

        switch model.family {
        case .moonshine:
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: files.tokens.path,
                numThreads: numThreads,
                provider: "cpu",
                modelType: "moonshine",
                moonshine: sherpaOnnxOfflineMoonshineModelConfig(
                    preprocessor: files.preprocessor!.path,
                    encoder: files.encoder.path,
                    uncachedDecoder: files.uncachedDecoder!.path,
                    cachedDecoder: files.cachedDecoder!.path
                )
            )
        case .transducer:
            modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: files.tokens.path,
                transducer: sherpaOnnxOfflineTransducerModelConfig(
                    encoder: files.encoder.path,
                    decoder: files.decoder!.path,
                    joiner: files.joiner!.path
                ),
                numThreads: numThreads,
                provider: "cpu",
                modelType: "zipformer",
                modelingUnit: "bpe",
                bpeVocab: files.bpeVocabulary!.path
            )
        }

        return sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16_000),
            modelConfig: modelConfig
        )
    }
}
