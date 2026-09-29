import CryptoKit
import Foundation
import os

@MainActor
final class BlueModelManager: ObservableObject {
    static let shared = BlueModelManager()
    static let packageName = "blue-onnx-v2"
    static let displayName = String(localized: "Blue v2 (Hebrew and English, on-device)")

    @Published private(set) var isInstalled = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isPaused = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadFraction = 0.0
    @Published private(set) var statusText: String?

    let modelsDirectory: URL
    private let packageDirectory: URL
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "BlueModelManager")
    private let stateStore = ModelDownloadStateStore()
    private let resumeStore = ModelDownloadResumeDataStore()
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    private var activeFile: BlueModelFile?
    private var pauseRequested = false
    private var engine: BlueEngine?

    private init() {
        modelsDirectory = AppStoragePaths.root.appendingPathComponent("TTSModels", isDirectory: true)
        packageDirectory = modelsDirectory.appendingPathComponent(Self.packageName, isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        refreshInstalled()
        let savedState = stateStore.load(for: Self.packageName)
        isPaused = savedState?.phase == .paused
        downloadFraction = savedState?.fractionCompleted ?? 0
    }

    func refreshInstalled() {
        isInstalled = BlueModelCatalog.files.allSatisfy { file in
            let url = packageDirectory.appendingPathComponent(file.path)
            guard let data = try? Data(contentsOf: url) else { return false }
            return Self.sha256(data) == file.sha256
        } && EspeakDataSupport.containsData(in: modelsDirectory)
    }

    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        isPaused = false
        pauseRequested = false
        let state = ModelDownloadState(phase: .downloading)
        try? stateStore.save(state, for: Self.packageName)
        defer { isDownloading = false; downloadProgress = nil; activeFile = nil }

        do {
            try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
            var downloadFiles = BlueModelCatalog.files
            if !EspeakDataSupport.containsData(in: modelsDirectory) {
                downloadFiles.append(BlueModelCatalog.espeakDataArchive)
            }
            let missingFiles = downloadFiles.filter { file in
                let url = packageDirectory.appendingPathComponent(file.path)
                guard let data = try? Data(contentsOf: url) else { return true }
                return Self.sha256(data) != file.sha256
            }
            for (index, file) in missingFiles.enumerated() {
                try Task.checkCancellation()
                activeFile = file
                let progressFormat = String(localized: "Downloading Blue model %lld of %lld…")
                statusText = String.localizedStringWithFormat(progressFormat, index + 1, missingFiles.count)
                let destination = packageDirectory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = try await downloadFile(
                    file,
                    overallStart: Double(index) / Double(max(1, missingFiles.count)),
                    overallScale: 1 / Double(max(1, missingFiles.count))
                )
                let data = try Data(contentsOf: temporary)
                guard Self.sha256(data) == file.sha256 else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw TTSError.notAvailable(String(localized: "Blue model checksum validation failed."))
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                downloadFraction = Double(index + 1) / Double(max(1, missingFiles.count))
                downloadProgress = downloadFraction
                try? stateStore.save(ModelDownloadState(phase: .downloading, fractionCompleted: downloadFraction), for: Self.packageName)
            }
            if !EspeakDataSupport.containsData(in: modelsDirectory) {
                let archive = packageDirectory.appendingPathComponent(BlueModelCatalog.espeakDataArchive.path)
                let destination = packageDirectory.appendingPathComponent(EspeakDataSupport.directoryName, isDirectory: true)
                try EspeakDataSupport.extractTarBz2(at: archive, into: modelsDirectory, destination: destination)
                try? FileManager.default.removeItem(at: archive)
            }
            refreshInstalled()
            guard isInstalled else { throw TTSError.notAvailable(String(localized: "Blue model download is incomplete.")) }
            statusText = nil
            try? stateStore.save(ModelDownloadState(phase: .completed, fractionCompleted: 1), for: Self.packageName)
        } catch is CancellationError {
            isPaused = pauseRequested
            statusText = isPaused ? String(localized: "Paused") : String(localized: "Download cancelled")
            let fraction = downloadProgress ?? downloadFraction
            downloadFraction = fraction
            try? stateStore.save(ModelDownloadState(phase: isPaused ? .paused : .queued, fractionCompleted: fraction), for: Self.packageName)
        } catch {
            statusText = error.localizedDescription
            logger.error("Blue model download failed: \(error.localizedDescription, privacy: .public)")
            try? stateStore.save(ModelDownloadState(phase: .failed, fractionCompleted: downloadFraction, message: error.localizedDescription), for: Self.packageName)
        }
    }

    func pauseDownload() {
        guard let downloadTask else { return }
        pauseRequested = true
        let fileID = Self.packageName + "." + (activeFile?.path ?? "")
        downloadTask.cancel(byProducingResumeData: { [resumeStore] resumeData in
            if let resumeData { try? resumeStore.save(resumeData, for: fileID) }
        })
    }

    func resumeDownload() {
        guard !isDownloading else { return }
        Task { await download() }
    }

    func cancelDownload() {
        pauseRequested = false
        isPaused = false
        if let activeFile { resumeStore.remove(for: Self.packageName + "." + activeFile.path) }
        downloadTask?.cancel()
        statusText = String(localized: "Download cancelled")
    }

    func delete() {
        engine = nil
        try? FileManager.default.removeItem(at: packageDirectory)
        refreshInstalled()
    }

    func synthesize(text: String, language: String, speed: Double) async throws -> TTSAudio {
        guard isInstalled else {
            throw TTSError.notAvailable(String(localized: "Download Blue v2 in Read Aloud settings before using this voice."))
        }
        let engine = engine ?? BlueEngine(
            modelDirectory: packageDirectory,
            dataDirectory: EspeakDataSupport.dataDirectory(in: modelsDirectory)
        )
        self.engine = engine
        return try await engine.synthesize(text: text, language: language, speed: speed)
    }

    private func downloadFile(_ file: BlueModelFile, overallStart: Double, overallScale: Double) async throws -> URL {
        let fileID = Self.packageName + "." + file.path
        let resumeData = resumeStore.load(for: fileID)
        let stagingDirectory = packageDirectory
        let resumeStore = self.resumeStore
        let downloadLogger = logger
        return try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { [weak self, stagingDirectory, resumeStore, downloadLogger] location, response, error in
                Task { @MainActor in self?.downloadTask = nil }
                if let error {
                    continuation.resume(throwing: (error as NSError).code == NSURLErrorCancelled ? CancellationError() : error)
                    return
                }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let location else {
                    downloadLogger.error("Blue download response rejected: file=\(file.path, privacy: .public) status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public) hasLocation=\(location != nil, privacy: .public)")
                    continuation.resume(throwing: TTSError.badResponse)
                    return
                }
                let stagedFile = stagingDirectory.appendingPathComponent(".blue-download-\(UUID().uuidString).tmp")
                do {
                    try FileManager.default.moveItem(at: location, to: stagedFile)
                } catch {
                    downloadLogger.error("Blue download staging failed: file=\(file.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: TTSError.badResponse)
                    return
                }
                resumeStore.remove(for: fileID)
                continuation.resume(returning: stagedFile)
            }
            let task = resumeData.map { URLSession.shared.downloadTask(withResumeData: $0, completionHandler: completion) }
                ?? URLSession.shared.downloadTask(with: file.url, completionHandler: completion)
            self.downloadTask = task
            self.progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in
                    let fraction = min(1, overallStart + progress.fractionCompleted * overallScale)
                    self?.downloadProgress = fraction
                    self?.downloadFraction = fraction
                }
            }
            task.resume()
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
