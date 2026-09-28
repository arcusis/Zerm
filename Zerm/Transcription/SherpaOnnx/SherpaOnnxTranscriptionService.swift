import Foundation

final class SherpaOnnxTranscriptionService: TranscriptionService {
    private let modelsRoot: URL
    private let modelDirectoryOverride: URL?

    init(
        modelsRoot: URL = AppStoragePaths.root.appendingPathComponent("SherpaOnnxModels", isDirectory: true),
        modelDirectoryOverride: URL? = nil
    ) {
        self.modelsRoot = modelsRoot
        self.modelDirectoryOverride = modelDirectoryOverride
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        try Task.checkCancellation()
        guard let model = model as? SherpaOnnxModel, model.provider == .sherpaOnnx else {
            throw ZermEngineError.modelLoadFailed
        }

        let directory = modelDirectoryOverride ?? SherpaOnnxModelManager.modelDirectory(for: model, under: modelsRoot)
        let files = SherpaOnnxRecognizerConfiguration.files(for: model, in: directory)
        guard files.requiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ZermEngineError.modelLoadFailed
        }

        let samples = try await AudioProcessor().processAudioToSamples(audioURL)
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw ZermEngineError.transcriptionFailed }

        var config = SherpaOnnxRecognizerConfiguration.makeConfig(for: model, in: directory)
        let recognizer = withUnsafePointer(to: &config) {
            SherpaOnnxOfflineRecognizer(config: $0)
        }
        let result = recognizer.decode(samples: samples, sampleRate: 16_000)
        try Task.checkCancellation()
        return result.text
    }
}
