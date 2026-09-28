import AVFoundation
import Foundation
import Testing
@testable import Zerm

@MainActor
struct SherpaOnnxTranscriptionTests {
    private let tiny = try! #require(TranscriptionModelRegistry.models.first { $0.name == "sherpa-moonshine-tiny-en" } as? SherpaOnnxModel)
    private let base = try! #require(TranscriptionModelRegistry.models.first { $0.name == "sherpa-moonshine-base-en" } as? SherpaOnnxModel)
    private let russian = try! #require(TranscriptionModelRegistry.models.first { $0.name == "sherpa-zipformer-ru-vosk-int8" } as? SherpaOnnxModel)

    @Test func recognizerFilesUseMoonshineV1AndTransducerLayouts() {
        let root = URL(fileURLWithPath: "/tmp/models", isDirectory: true)
        let tinyFiles = SherpaOnnxRecognizerConfiguration.files(for: tiny, in: root)
        #expect(tinyFiles.preprocessor?.lastPathComponent == "preprocess.onnx")
        #expect(tinyFiles.encoder.lastPathComponent == "encode.int8.onnx")
        #expect(tinyFiles.uncachedDecoder?.lastPathComponent == "uncached_decode.int8.onnx")
        #expect(tinyFiles.cachedDecoder?.lastPathComponent == "cached_decode.int8.onnx")
        #expect(tinyFiles.decoder == nil && tinyFiles.joiner == nil)

        let ruFiles = SherpaOnnxRecognizerConfiguration.files(for: russian, in: root)
        #expect(ruFiles.encoder.lastPathComponent == "encoder.int8.onnx")
        #expect(ruFiles.decoder?.lastPathComponent == "decoder.onnx")
        #expect(ruFiles.joiner?.lastPathComponent == "joiner.int8.onnx")
        #expect(ruFiles.bpeVocabulary?.lastPathComponent == "bpe.model")
        #expect(ruFiles.preprocessor == nil)

        let tinyConfig = SherpaOnnxRecognizerConfiguration.makeConfig(for: tiny, in: root, numThreads: 2)
        let baseConfig = SherpaOnnxRecognizerConfiguration.makeConfig(for: base, in: root, numThreads: 2)
        let ruConfig = SherpaOnnxRecognizerConfiguration.makeConfig(for: russian, in: root, numThreads: 2)
        #expect(tinyConfig.feat_config.sample_rate == 16_000)
        #expect(baseConfig.feat_config.sample_rate == 16_000)
        #expect(ruConfig.feat_config.sample_rate == 16_000)
    }

    @Test func catalogCarriesVerifiedModelProvenance() {
        #expect(tiny.provenance?.creator == "Useful Sensors")
        #expect(tiny.provenance?.licenseSPDX == "MIT")
        #expect(base.provenance?.creator == "Useful Sensors")
        #expect(base.provenance?.licenseSPDX == "MIT")
        #expect(russian.provenance?.creator == "Alpha Cephei (Vosk)")
        #expect(russian.provenance?.licenseSPDX == "Apache-2.0")
        #expect(russian.supportedLanguages["ru"] == "Russian")
        #expect(russian.languageGroup == .singleLanguage)
    }

    @Test func archiveExtractionRejectsTraversalAndPlatformPaths() throws {
        try SherpaOnnxModelManager.assertSafeArchivePaths([
            "model/", "model/tokens.txt", "model/sub/encoder.onnx"
        ])
        for path in ["../outside", "model/../../outside", "/tmp/outside", "C:\\outside", "model/./tokens.txt"] {
            #expect(throws: Error.self) {
                try SherpaOnnxModelManager.assertSafeArchivePaths([path])
            }
        }
        try SherpaOnnxModelManager.assertSafeArchiveTypes(["d", "-"])
        for type in ["l", "h", "b", "c"] {
            #expect(throws: Error.self) {
                try SherpaOnnxModelManager.assertSafeArchiveTypes([Character(type)])
            }
        }
    }

    @Test func optionalRussianIntegrationTranscribesGeneratedShortClip() async throws {
        guard let modelDirectoryPath = ProcessInfo.processInfo.environment["ZERMSHERPA_RU_MODEL_DIR"] else { return }
        let modelDirectory = URL(fileURLWithPath: modelDirectoryPath, isDirectory: true)
        let source = modelDirectory.appendingPathComponent("test_wavs/1.wav")
        let generatedClip = FileManager.default.temporaryDirectory.appendingPathComponent("sherpa-ru-clip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: generatedClip) }
        try await Self.writeShortClip(from: source, to: generatedClip)

        let service = SherpaOnnxTranscriptionService(modelDirectoryOverride: modelDirectory)
        let text = try await service.transcribe(audioURL: generatedClip, model: russian)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func optionalCorpusRunPrintsFiveClipsPerLanguage() async throws {
        guard ProcessInfo.processInfo.environment["ZERMSHERPA_RUN_CORPUS"] == "1",
              let tinyPath = ProcessInfo.processInfo.environment["ZERMSHERPA_TINY_MODEL_DIR"],
              let ruPath = ProcessInfo.processInfo.environment["ZERMSHERPA_RU_MODEL_DIR"] else { return }

        let englishService = SherpaOnnxTranscriptionService(modelDirectoryOverride: URL(fileURLWithPath: tinyPath, isDirectory: true))
        let russianService = SherpaOnnxTranscriptionService(modelDirectoryOverride: URL(fileURLWithPath: ruPath, isDirectory: true))
        var transcripts: [String] = []
        for index in 1...5 {
            let audio = URL(fileURLWithPath: "/tmp/fabench/corpus/s\(index).wav")
            let text = try await englishService.transcribe(audioURL: audio, model: tiny)
            transcripts.append("en s\(index): \(text)")
        }
        for index in 1...5 {
            let audio = URL(fileURLWithPath: "/tmp/langcorpus/ru\(index).wav")
            let text = try await russianService.transcribe(audioURL: audio, model: russian)
            transcripts.append("ru ru\(index): \(text)")
        }
        let report = URL(fileURLWithPath: "/tmp/zerm-work/376-corpus-transcripts.txt")
        try (transcripts.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
    }

    private static func writeShortClip(from source: URL, to destination: URL) async throws {
        let samples = try await AudioProcessor().processAudioToSamples(source)
        let clipSamples = Array(samples.prefix(16_000 * 5))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clipSamples.count))!
        buffer.frameLength = AVAudioFrameCount(clipSamples.count)
        clipSamples.withUnsafeBufferPointer { samples in
            buffer.floatChannelData![0].update(from: samples.baseAddress!, count: clipSamples.count)
        }
        try file.write(from: buffer)
    }
}
