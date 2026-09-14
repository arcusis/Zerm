import Foundation
import os
import Zip
import SwiftUI
import Atomics

// MARK: - WhisperModelFile

struct WhisperModelFile: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    var coreMLEncoderURL: URL? // Path to the unzipped .mlmodelc directory
    var isCoreMLDownloaded: Bool { coreMLEncoderURL != nil }

    var filename: String {
        "\(name).bin"
    }

    /// Pinned SHA-256 for the main `.bin`, if this is a known catalog model.
    var expectedSHA256: String? {
        ModelIntegrity.whisperSHA256[name]
    }

    /// Only non-quantized whisper.cpp releases ship a Core ML encoder; fine-tunes from other
    /// repositories (ivrit.ai) run on Metal alone.
    static func hasCoreMLEncoder(modelName: String) -> Bool {
        modelName.hasPrefix("ggml-") && !modelName.contains("q5") && !modelName.contains("q8")
    }

    // Core ML related properties
    var coreMLZipDownloadURL: String? {
        guard Self.hasCoreMLEncoder(modelName: name) else { return nil }
        return ModelIntegrity.PinnedFile.whisperCpp(fileName: "\(name)-encoder.mlmodelc.zip").downloadURL
    }

    var coreMLEncoderDirectoryName: String? {
        guard coreMLZipDownloadURL != nil else { return nil }
        return "\(name)-encoder.mlmodelc"
    }
}

// MARK: - Private download task delegate

private class TaskDelegate: NSObject, URLSessionTaskDelegate {
    private let continuation: CheckedContinuation<Void, Never>
    private let finished = ManagedAtomic(false)

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if finished.exchange(true, ordering: .acquiring) == false {
            continuation.resume()
        }
    }
}

// MARK: - WhisperModelManager

@MainActor
class WhisperModelManager: ObservableObject {
    @Published var availableModels: [WhisperModelFile] = []
    @Published var downloadProgress: [String: Double] = [:]
    /// Last download failure per model name, shown on the model card with a retry.
    @Published var downloadErrors: [String: String] = [:]
    @Published var whisperContext: WhisperContext?
    @Published var isModelLoaded = false
    @Published var loadedWhisperModel: WhisperModelFile?
    @Published var isModelLoading = false

    let modelsDirectory: URL
    let whisperPrompt = WhisperPrompt()

    /// Called when a model is deleted, passing the model name.
    /// TranscriptionModelManager listens to clear currentTranscriptionModel if needed.
    var onModelDeleted: ((String) -> Void)?

    /// Called after a new model is added (downloaded or imported) so
    /// TranscriptionModelManager can rebuild allAvailableModels.
    var onModelsChanged: (() -> Void)?

    let logger = Logger(subsystem: "com.arcusis.zerm", category: "WhisperModelManager")

    private let contextLoader: (URL) async throws -> WhisperContext
    /// The load in flight, so concurrent requests for the same model share one context.
    private var pendingLoad: (name: String, task: Task<WhisperContext, Error>)?

    init(
        modelsDirectory: URL,
        contextLoader: @escaping (URL) async throws -> WhisperContext = { try await WhisperContext.createContext(path: $0.path) }
    ) {
        self.modelsDirectory = modelsDirectory
        self.contextLoader = contextLoader
    }

    // MARK: - Model Directory Management

    func createModelsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logError("Error creating models directory", error)
        }
    }

    func loadAvailableModels() {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil)
            availableModels = fileURLs.compactMap { url in
                guard url.pathExtension == "bin" else { return nil }
                return WhisperModelFile(name: url.deletingPathExtension().lastPathComponent, url: url)
            }
        } catch {
            logError("Error loading available models", error)
        }
    }

    // MARK: - Model Loading

    /// Returns the resident context for `model`, loading it once if needed. A different
    /// resident model is released first so only one Whisper context is ever held.
    @discardableResult
    func loadModel(_ model: WhisperModelFile) async throws -> WhisperContext {
        if let whisperContext, loadedWhisperModel?.name == model.name {
            return whisperContext
        }
        if let pendingLoad, pendingLoad.name == model.name {
            return try await pendingLoad.task.value
        }

        let previousContext = whisperContext
        resetLoadedState()

        let loader = contextLoader
        let url = model.url
        let task = Task { try await loader(url) }
        pendingLoad = (model.name, task)
        isModelLoading = true

        await previousContext?.releaseResources()

        let context: WhisperContext
        do {
            context = try await task.value
        } catch {
            if pendingLoad?.task == task {
                pendingLoad = nil
                isModelLoading = false
            }
            logger.error("❌ Failed to load model \(model.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ZermEngineError.modelLoadFailed
        }

        // The model was switched or released while loading; don't resurrect it.
        guard pendingLoad?.task == task else {
            await context.releaseResources()
            throw CancellationError()
        }

        let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? whisperPrompt.transcriptionPrompt
        await context.setPrompt(currentPrompt)

        pendingLoad = nil
        isModelLoading = false
        whisperContext = context
        loadedWhisperModel = model
        isModelLoaded = true
        return context
    }

    /// Returns the resident context for the model named `name`, loading it once if needed.
    func loadModel(named name: String) async throws -> WhisperContext {
        if let whisperContext, loadedWhisperModel?.name == name {
            return whisperContext
        }
        guard let model = availableModels.first(where: { $0.name == name }),
              FileManager.default.fileExists(atPath: model.url.path) else {
            logger.error("❌ Model file not found for: \(name, privacy: .public)")
            throw ZermEngineError.modelLoadFailed
        }
        return try await loadModel(model)
    }

    /// Releases the resident or loading model unless it is the one named `name`.
    func releaseModel(otherThan name: String) {
        guard let current = loadedWhisperModel?.name ?? pendingLoad?.name, current != name else { return }
        unloadModel()
    }

    private func resetLoadedState() {
        whisperContext = nil
        loadedWhisperModel = nil
        isModelLoaded = false
        pendingLoad = nil
        isModelLoading = false
    }

    // MARK: - Model Download & Management

    private func downloadFileWithProgress(from url: URL, progressKey: String) async throws -> Data {
        let destinationURL = modelsDirectory.appendingPathComponent(UUID().uuidString)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let finished = ManagedAtomic(false)

            func finishOnce(_ result: Result<Data, Error>) {
                if finished.exchange(true, ordering: .acquiring) == false {
                    continuation.resume(with: result)
                }
            }

            let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    finishOnce(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode),
                      let tempURL = tempURL else {
                    finishOnce(.failure(URLError(.badServerResponse)))
                    return
                }

                do {
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    let data = try Data(contentsOf: destinationURL, options: .mappedIfSafe)
                    finishOnce(.success(data))
                    try? FileManager.default.removeItem(at: destinationURL)
                } catch {
                    finishOnce(.failure(error))
                }
            }

            task.resume()

            var lastUpdateTime = Date()
            var lastProgressValue: Double = 0

            let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let currentTime = Date()
                let timeSinceLastUpdate = currentTime.timeIntervalSince(lastUpdateTime)
                let currentProgress = round(progress.fractionCompleted * 100) / 100

                if timeSinceLastUpdate >= 0.5 && abs(currentProgress - lastProgressValue) >= 0.01 {
                    lastUpdateTime = currentTime
                    lastProgressValue = currentProgress

                    DispatchQueue.main.async {
                        self.downloadProgress[progressKey] = currentProgress
                    }
                }
            }

            Task {
                await withTaskCancellationHandler {
                    // Parks until this task is cancelled; the download completes through
                    // the observation above, not through this continuation.
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                } onCancel: {
                    observation.invalidate()
                    if finished.exchange(true, ordering: .acquiring) == false {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }
    }

    func downloadModel(_ model: WhisperModel) async {
        guard !model.hardwareFit.blocksInstall else { return }
        guard let url = URL(string: model.downloadURL) else { return }
        await performModelDownload(model, url)
    }

    private enum DownloadError: LocalizedError {
        case checksumMismatch

        var errorDescription: String? {
            String(localized: "The downloaded file did not match its published checksum and was discarded. Try again.")
        }
    }

    private func performModelDownload(_ model: WhisperModel, _ url: URL) async {
        downloadErrors[model.name] = nil
        do {
            var whisperModel = try await downloadMainModel(model, from: url)

            if let coreMLZipURL = whisperModel.coreMLZipDownloadURL,
               let coreMLURL = URL(string: coreMLZipURL) {
                whisperModel = try await downloadAndSetupCoreMLModel(for: whisperModel, from: coreMLURL)
            }

            availableModels.append(whisperModel)
            self.downloadProgress.removeValue(forKey: model.name + "_main")

            onModelsChanged?()

            if shouldWarmup(model) {
                WhisperModelWarmupCoordinator.shared.scheduleWarmup(for: model, whisperModelManager: self)
            }
        } catch {
            handleModelDownloadError(model, error)
        }
    }

    private func downloadMainModel(_ model: WhisperModel, from url: URL) async throws -> WhisperModelFile {
        let progressKeyMain = model.name + "_main"
        let data = try await downloadFileWithProgress(from: url, progressKey: progressKeyMain)

        let destinationURL = modelsDirectory.appendingPathComponent(model.filename)
        try data.write(to: destinationURL)

        // Reject a tampered/corrupt download before whisper.cpp ever parses it.
        if !ModelIntegrity.verify(fileURL: destinationURL, expectedSHA256: ModelIntegrity.whisperSHA256[model.name]) {
            try? FileManager.default.removeItem(at: destinationURL)
            logger.error("Checksum mismatch for model \(model.name, privacy: .public); download rejected")
            throw DownloadError.checksumMismatch
        }

        return WhisperModelFile(name: model.name, url: destinationURL)
    }

    private func downloadAndSetupCoreMLModel(for model: WhisperModelFile, from url: URL) async throws -> WhisperModelFile {
        let progressKeyCoreML = model.name + "_coreml"
        let coreMLData = try await downloadFileWithProgress(from: url, progressKey: progressKeyCoreML)

        let coreMLZipPath = modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc.zip")
        try coreMLData.write(to: coreMLZipPath)

        return try await unzipAndSetupCoreMLModel(for: model, zipPath: coreMLZipPath, progressKey: progressKeyCoreML)
    }

    private func unzipAndSetupCoreMLModel(for model: WhisperModelFile, zipPath: URL, progressKey: String) async throws -> WhisperModelFile {
        let coreMLDestination = modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc")

        try? FileManager.default.removeItem(at: coreMLDestination)
        try await unzipCoreMLFile(zipPath, to: modelsDirectory)
        return try verifyAndCleanupCoreMLFiles(model, coreMLDestination, zipPath, progressKey)
    }

    /// Rejects a zip whose entries would escape the extraction directory (zip-slip). The
    /// bundled Zip library performs no containment check and the app is not sandboxed, so a
    /// malicious `.mlmodelc.zip` could otherwise write anywhere the user can. Lists entry
    /// names with `/usr/bin/unzip -Z1` and fails closed on any absolute path or `..` component.
    static func assertNoPathTraversal(inZipAt zipPath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", zipPath.path]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ZermEngineError.unzipFailed
        }
        let names = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for name in names where !name.isEmpty {
            let isAbsolute = name.hasPrefix("/")
            let hasTraversal = name == ".." || name.hasPrefix("../") || name.contains("/../") || name.hasSuffix("/..")
            if isAbsolute || hasTraversal {
                throw ZermEngineError.unzipFailed
            }
        }
    }

    private func unzipCoreMLFile(_ zipPath: URL, to destination: URL) async throws {
        let finished = ManagedAtomic(false)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            func finishOnce(_ result: Result<Void, Error>) {
                if finished.exchange(true, ordering: .acquiring) == false {
                    continuation.resume(with: result)
                }
            }

            do {
                try Self.assertNoPathTraversal(inZipAt: zipPath)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Zip.unzipFile(zipPath, destination: destination, overwrite: true, password: nil)
                finishOnce(.success(()))
            } catch {
                finishOnce(.failure(error))
            }
        }
    }

    private func verifyAndCleanupCoreMLFiles(_ model: WhisperModelFile, _ destination: URL, _ zipPath: URL, _ progressKey: String) throws -> WhisperModelFile {
        var model = model

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            try? FileManager.default.removeItem(at: zipPath)
            throw ZermEngineError.unzipFailed
        }

        try? FileManager.default.removeItem(at: zipPath)
        model.coreMLEncoderURL = destination
        self.downloadProgress.removeValue(forKey: progressKey)

        return model
    }

    private func shouldWarmup(_ model: WhisperModel) -> Bool {
        !model.name.contains("q5") && !model.name.contains("q8")
    }

    private func handleModelDownloadError(_ model: WhisperModel, _ error: Error) {
        self.downloadProgress.removeValue(forKey: model.name + "_main")
        self.downloadProgress.removeValue(forKey: model.name + "_coreml")
        downloadErrors[model.name] = error.localizedDescription
        logError("Download failed for \(model.name)", error)
    }

    func deleteModel(_ model: WhisperModelFile) async {
        do {
            try FileManager.default.removeItem(at: model.url)

            if let coreMLURL = model.coreMLEncoderURL {
                try? FileManager.default.removeItem(at: coreMLURL)
            } else {
                let coreMLDir = modelsDirectory.appendingPathComponent("\(model.name)-encoder.mlmodelc")
                if FileManager.default.fileExists(atPath: coreMLDir.path) {
                    try? FileManager.default.removeItem(at: coreMLDir)
                }
            }

            availableModels.removeAll { $0.id == model.id }

            // Notify TranscriptionModelManager to clear currentTranscriptionModel if it matches
            onModelDeleted?(model.name)
        } catch {
            logError("Error deleting model: \(model.name)", error)
        }
    }

    func unloadModel() {
        let context = whisperContext
        resetLoadedState()
        Task {
            await context?.releaseResources()
        }
    }

    func clearDownloadedModels() async {
        for model in availableModels {
            do {
                try FileManager.default.removeItem(at: model.url)
            } catch {
                logError("Error deleting model during cleanup", error)
            }
        }
        availableModels.removeAll()
    }

    // MARK: - Resource Management

    /// Releases the WhisperContext and resets model-loaded state.
    /// Does NOT call serviceRegistry.cleanup() — that is ZermEngine's responsibility.
    func cleanupResources() async {
        logger.notice("WhisperModelManager.cleanupResources: releasing whisper context")
        let context = whisperContext
        resetLoadedState()
        await context?.releaseResources()
        logger.notice("WhisperModelManager.cleanupResources: completed")
    }

    // MARK: - Import Local Model

    func importWhisperModel(from sourceURL: URL) async {
        guard sourceURL.pathExtension.lowercased() == "bin" else { return }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let destinationURL = modelsDirectory.appendingPathComponent("\(baseName).bin")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            NotificationManager.shared.showNotification(
                title: String(localized: "A model named \(baseName).bin already exists"),
                type: .warning,
                duration: 4.0
            )
            return
        }

        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let newWhisperModel = WhisperModelFile(name: baseName, url: destinationURL)
            availableModels.append(newWhisperModel)

            onModelsChanged?()

            NotificationManager.shared.showNotification(
                title: String(localized: "Imported \(destinationURL.lastPathComponent)"),
                type: .success,
                duration: 3.0
            )
        } catch {
            logError("Failed to import local model", error)
            NotificationManager.shared.showNotification(
                title: String(localized: "Failed to import model: \(error.localizedDescription)"),
                type: .error,
                duration: 5.0
            )
        }
    }

    // MARK: - Helpers

    private func logError(_ message: String, _ error: Error) {
        logger.error("❌ \(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - WhisperModelProvider

extension WhisperModelManager: WhisperModelProvider {}

// MARK: - Download Progress View

struct DownloadProgressView: View {
    let modelName: String
    let downloadProgress: [String: Double]

    @Environment(\.colorScheme) private var colorScheme

    private var mainProgress: Double {
        downloadProgress[modelName + "_main"] ?? 0
    }

    private var coreMLProgress: Double {
        supportsCoreML ? (downloadProgress[modelName + "_coreml"] ?? 0) : 0
    }

    private var supportsCoreML: Bool {
        WhisperModelFile.hasCoreMLEncoder(modelName: modelName)
    }

    private var totalProgress: Double {
        supportsCoreML ? (mainProgress * 0.5) + (coreMLProgress * 0.5) : mainProgress
    }

    private var downloadPhase: String {
        if supportsCoreML && downloadProgress[modelName + "_coreml"] != nil {
            return String(localized: "Downloading Core ML Model for \(modelName)")
        }
        return String(localized: "Downloading \(modelName) Model")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: downloadPhase)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(.secondaryLabelColor))

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.separatorColor).opacity(0.3))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.controlAccentColor))
                        .frame(width: max(0, min(geometry.size.width * totalProgress, geometry.size.width)), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                Spacer()
                Text(verbatim: "\(Int(totalProgress * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(.secondaryLabelColor))
            }
        }
        .padding(.vertical, 4)
        .animation(.smooth, value: totalProgress)
    }
}
