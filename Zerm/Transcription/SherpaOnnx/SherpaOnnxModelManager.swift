import Foundation
import SwiftUI

@MainActor
final class SherpaOnnxModelManager: ObservableObject {
    @Published private(set) var downloadingModels = Set<String>()
    @Published var downloadProgress: [String: Double] = [:]
    @Published private(set) var downloadStates: [String: ModelDownloadState] = [:]
    @Published private(set) var downloadErrors: [String: String] = [:]

    private let storageRoot: URL
    private let resumeDataStore = ModelDownloadResumeDataStore()
    private let downloadStateStore = ModelDownloadStateStore()
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadRequests: [String: ModelDownloadRequest] = [:]
    private var pausedDownloads = Set<String>()
    var onModelDeleted: ((String) -> Void)?

    init(storageRoot: URL = AppStoragePaths.root) {
        self.storageRoot = storageRoot
        for model in TranscriptionModelRegistry.models.compactMap({ $0 as? SherpaOnnxModel }) {
            if let state = downloadStateStore.load(for: model.name) { downloadStates[model.name] = state }
        }
    }

    nonisolated static func modelDirectory(for model: SherpaOnnxModel, under root: URL = AppStoragePaths.root.appendingPathComponent("SherpaOnnxModels", isDirectory: true)) -> URL {
        root.appendingPathComponent(model.name, isDirectory: true)
    }

    func isDownloaded(_ model: SherpaOnnxModel) -> Bool {
        let directory = Self.modelDirectory(for: model, under: storageRoot.appendingPathComponent("SherpaOnnxModels", isDirectory: true))
        return Self.requiredFiles(for: model).allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    func startDownload(_ model: SherpaOnnxModel) {
        guard downloadTasks[model.name] == nil, !isDownloaded(model) else { return }
        let hasResumeData = resumeDataStore.load(for: model.name) != nil
        downloadStates[model.name] = ModelDownloadState(phase: hasResumeData ? .resuming : .downloading)
        downloadErrors[model.name] = nil
        try? downloadStateStore.save(downloadStates[model.name]!, for: model.name)
        pausedDownloads.remove(model.name)
        downloadingModels.insert(model.name)
        downloadTasks[model.name] = Task { [weak self] in
            await self?.downloadModel(model)
            self?.downloadTasks[model.name] = nil
            self?.downloadingModels.remove(model.name)
        }
    }

    func download(_ model: SherpaOnnxModel) async throws {
        try await performDownload(model)
    }

    func pauseDownload(_ model: SherpaOnnxModel) {
        guard let request = downloadRequests[model.name] else { return }
        pausedDownloads.insert(model.name)
        request.pause(resumeDataStore: resumeDataStore, assetID: model.name)
    }

    func cancelDownload(_ model: SherpaOnnxModel) {
        pausedDownloads.remove(model.name)
        downloadTasks[model.name]?.cancel()
        downloadRequests[model.name]?.cancel()
        resumeDataStore.remove(for: model.name)
        downloadStates[model.name] = ModelDownloadState(phase: .queued)
        downloadProgress.removeValue(forKey: model.name)
        try? downloadStateStore.save(downloadStates[model.name]!, for: model.name)
    }

    func isPaused(_ model: SherpaOnnxModel) -> Bool {
        downloadStates[model.name]?.phase == .paused
    }

    func resumeDownload(_ model: SherpaOnnxModel) {
        guard isPaused(model) else { return }
        Task { @MainActor in
            while downloadTasks[model.name] != nil { try? await Task.sleep(for: .milliseconds(20)) }
            startDownload(model)
        }
    }

    func downloadModel(_ model: SherpaOnnxModel) async {
        do {
            try await performDownload(model)
            var state = ModelDownloadState(phase: .completed, fractionCompleted: 1)
            state.totalBytes = state.bytesDownloaded
            downloadStates[model.name] = state
            try? downloadStateStore.save(state, for: model.name)
            downloadProgress.removeValue(forKey: model.name)
        } catch {
            if pausedDownloads.contains(model.name) {
                var state = downloadStates[model.name] ?? ModelDownloadState(phase: .paused)
                state.phase = .paused
                downloadStates[model.name] = state
            } else if (error as? URLError)?.code != .cancelled {
                var state = downloadStates[model.name] ?? ModelDownloadState(phase: .failed)
                state.phase = .failed
                state.message = error.localizedDescription
                downloadStates[model.name] = state
                downloadErrors[model.name] = error.localizedDescription
            }
            if let state = downloadStates[model.name] { try? downloadStateStore.save(state, for: model.name) }
        }
    }

    private func performDownload(_ model: SherpaOnnxModel) async throws {
        guard !isDownloaded(model) else { return }
        let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(model.archiveName)")!
        let archiveURL = try await downloadArchive(from: url, assetID: model.name)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        guard ModelIntegrity.verify(fileURL: archiveURL, expectedSHA256: model.sha256) else {
            throw DownloadError.checksumMismatch
        }

        let parent = storageRoot.appendingPathComponent("SherpaOnnxModels", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryDirectory = parent.appendingPathComponent(".\(model.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Self.extractSafely(archiveURL, to: temporaryDirectory)

        let extracted = temporaryDirectory.appendingPathComponent(Self.archiveDirectory(for: model), isDirectory: true)
        guard Self.requiredFiles(for: model).allSatisfy({ FileManager.default.fileExists(atPath: extracted.appendingPathComponent($0).path) }) else {
            throw DownloadError.invalidArchive
        }

        let destination = Self.modelDirectory(for: model, under: parent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: extracted, to: destination)
        resumeDataStore.remove(for: model.name)
    }

    private func downloadArchive(from url: URL, assetID: String) async throws -> URL {
        if let resumeData = resumeDataStore.load(for: assetID) {
            do {
                return try await downloadArchive(from: url, assetID: assetID, resumeData: resumeData)
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                resumeDataStore.remove(for: assetID)
            }
        }
        return try await downloadArchive(from: url, assetID: assetID, resumeData: nil)
    }

    private func downloadArchive(from url: URL, assetID: String, resumeData: Data?) async throws -> URL {
        let request = ModelDownloadRequest()
        let resumeStore = resumeDataStore
        let archiveURL = storageRoot.appendingPathComponent(".\(assetID)-\(UUID().uuidString).download")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = resumeData.map {
                    URLSession.shared.downloadTask(withResumeData: $0, completionHandler: completion)
                } ?? URLSession.shared.downloadTask(with: url, completionHandler: completion)
                let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.downloadProgress[assetID] = progress.fractionCompleted
                        var state = self.downloadStates[assetID] ?? ModelDownloadState(phase: .downloading)
                        state.fractionCompleted = progress.fractionCompleted
                        state.bytesDownloaded = progress.completedUnitCount
                        state.totalBytes = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
                        self.downloadStates[assetID] = state
                        try? self.downloadStateStore.save(state, for: assetID)
                    }
                }
                guard request.install(task: task, observation: observation) else {
                    observation.invalidate()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                downloadRequests[assetID] = request
                task.resume()

                func completion(_ temporaryURL: URL?, _ response: URLResponse?, _ error: Error?) {
                    defer {
                        request.finish()
                        Task { @MainActor in self.downloadRequests[assetID] = nil }
                    }
                    if let error { continuation.resume(throwing: error); return }
                    guard let response = response as? HTTPURLResponse,
                          (200...299).contains(response.statusCode), let temporaryURL else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
                        resumeStore.remove(for: assetID)
                        continuation.resume(returning: archiveURL)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    func delete(_ model: SherpaOnnxModel) throws {
        let directory = Self.modelDirectory(for: model, under: storageRoot.appendingPathComponent("SherpaOnnxModels", isDirectory: true))
        try FileManager.default.removeItem(at: directory)
        onModelDeleted?(model.name)
    }

    static func assertSafeArchivePaths(_ paths: [String]) throws {
        for path in paths where !path.isEmpty {
            guard !path.hasPrefix("/"), !path.contains("\\") else { throw DownloadError.invalidArchive }
            let components = path.split(separator: "/")
            guard !components.contains(".."), !components.contains(".") else { throw DownloadError.invalidArchive }
        }
    }

    static func assertSafeArchiveTypes(_ types: [Character]) throws {
        guard types.allSatisfy({ $0 == "-" || $0 == "d" }) else {
            throw DownloadError.invalidArchive
        }
    }

    private static func extractSafely(_ archive: URL, to destination: URL) throws {
        let names = try runTar(arguments: ["-tjf", archive.path])
            .split(separator: "\n")
            .map(String.init)
        try assertSafeArchivePaths(names)

        let verbose = try runTar(arguments: ["-tvjf", archive.path])
        let entries = verbose.split(separator: "\n")
        try assertSafeArchiveTypes(entries.compactMap(\.first))

        _ = try runTar(arguments: ["-xjf", archive.path, "-C", destination.path, "--no-same-owner", "--no-same-permissions"])
    }

    private static func runTar(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw DownloadError.invalidArchive
        }
        return text
    }

    private static func requiredFiles(for model: SherpaOnnxModel) -> [String] {
        switch model.family {
        case .moonshine:
            ["tokens.txt", "preprocess.onnx", "encode.int8.onnx", "uncached_decode.int8.onnx", "cached_decode.int8.onnx"]
        case .transducer:
            ["tokens.txt", "bpe.model", "encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx"]
        }
    }

    private static func archiveDirectory(for model: SherpaOnnxModel) -> String {
        model.archiveName.replacingOccurrences(of: ".tar.bz2", with: "")
    }

    private enum DownloadError: LocalizedError {
        case checksumMismatch
        case invalidArchive

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                String(localized: "The downloaded speech model failed its SHA-256 check.")
            case .invalidArchive:
                String(localized: "The downloaded speech model archive is invalid.")
            }
        }
    }
}
