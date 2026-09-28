import Foundation
import FluidAudio
import AppKit
import os

/// What a FluidAudio model's cache folder holds.
enum FluidAudioCacheState: Equatable {
    /// Everything the current FluidAudio loader needs.
    case complete
    /// A download from an older release. It loads once FluidAudio fetches the few files it
    /// added; the dictation load path fetches them itself and keeps the existing files.
    case needsUpdate
    /// Never downloaded, or deleted or half-migrated (#173): download required.
    case missing
}

enum FluidAudioModelError: LocalizedError {
    case updateDownloadRequired

    var errorDescription: String? {
        String(localized: "Parakeet needs a one-time update download. Connect to the internet and try again.")
    }
}

@MainActor
class FluidAudioModelManager: ObservableObject {
    @Published var parakeetDownloadStates: [String: Bool] = [:]
    @Published var downloadProgress: [String: Double] = [:]
    /// Last download failure per model name, shown on the model card with a retry.
    @Published var downloadErrors: [String: String] = [:]
    @Published private(set) var downloadStates: [String: ModelDownloadState] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "FluidAudioModelManager")
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var pausedDownloads: Set<String> = []
    private var cancelledDownloads: Set<String> = []
    private let downloadStateStore = ModelDownloadStateStore()

    // Add new Fluid Audio TDT models here when support is added.
    nonisolated static let modelVersionMap: [String: AsrModelVersion] = [
        "parakeet-tdt-ctc-110m": .tdtCtc110m,
        "parakeet-tdt-0.6b-v2": .v2,
        "parakeet-tdt-0.6b-v3": .v3,
        "parakeet-tdt-0.6b-redux": .redux,
        "parakeet-tdt-0.6b-ultra": .ultra,
    ]

    nonisolated static let reduxModelName = "parakeet-tdt-0.6b-redux"

    nonisolated static func supportsModel(_ modelName: String, macOSMajorVersion: Int) -> Bool {
        modelName != reduxModelName || macOSMajorVersion >= 15
    }

    nonisolated static func isModelAvailable(_ modelName: String) -> Bool {
        guard modelName == reduxModelName else { return true }
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Parakeet Unified is an RNNT model with its own manager, not a TDT version.
    nonisolated static let unifiedModelName = "parakeet-unified-en-0.6b"

    nonisolated static func asrVersion(for modelName: String) -> AsrModelVersion {
        modelVersionMap[modelName] ?? .v3
    }

    nonisolated static var unifiedCacheDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetUnified)
    }

    /// Files `UnifiedAsrManager.loadModels(from:)` needs for the int8 offline encoder.
    nonisolated static let unifiedRequiredFiles = [
        ModelNames.ParakeetUnified.offlineEncoderFile(precision: .int8),
        ModelNames.ParakeetUnified.decoderFile,
        ModelNames.ParakeetUnified.jointDecisionFile,
        ModelNames.ParakeetUnified.vocab,
    ]

    /// Parakeet V3 files every download made before FluidAudio 0.15.7 has. 0.15.7 added
    /// `JointDecisionv3.mlmodelc`, which its loader fetches on first load.
    nonisolated static let legacyV3Files = [
        ModelNames.ASR.preprocessorFile,
        ModelNames.ASR.encoderFile,
        ModelNames.ASR.decoderFile,
        ModelNames.ASR.vocabularyFile,
    ]

    /// `directory` is the model's own cache folder, named as FluidAudio names it (FluidAudio resolves
    /// the folder by name); injectable for tests.
    nonisolated static func cacheState(forModelNamed modelName: String, in directory: URL? = nil) -> FluidAudioCacheState {
        guard isModelAvailable(modelName) else { return .missing }
        func allExist(_ files: [String], in folder: URL) -> Bool {
            files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }

        if modelName == unifiedModelName {
            return allExist(unifiedRequiredFiles, in: directory ?? unifiedCacheDirectory) ? .complete : .missing
        }

        let version = asrVersion(for: modelName)
        let folder = directory ?? AsrModels.defaultCacheDirectory(for: version)
        if AsrModels.modelsExist(at: folder, version: version) {
            return .complete
        }
        if version == .v3, allExist(legacyV3Files, in: folder) {
            return .needsUpdate
        }
        return .missing
    }

    init() {
        for model in TranscriptionModelRegistry.models where model.provider == .fluidAudio {
            if let state = downloadStateStore.load(for: model.name) { downloadStates[model.name] = state }
        }
    }

    // MARK: - Query helpers

    /// Downloaded means the download finished once and its files are still on disk, including a
    /// cache from an older release that only lacks files FluidAudio fetches on load. A folder
    /// emptied by a storage migration or cleanup shows as "download required" instead of failing
    /// at dictation time. (#173)
    func isFluidAudioModelDownloaded(named modelName: String) -> Bool {
        UserDefaults.standard.bool(forKey: parakeetDefaultsKey(for: modelName))
            && Self.cacheState(forModelNamed: modelName) != .missing
    }

    func isFluidAudioModelDownloaded(_ model: FluidAudioModel) -> Bool {
        isFluidAudioModelDownloaded(named: model.name)
    }

    func isFluidAudioModelDownloading(_ model: FluidAudioModel) -> Bool {
        parakeetDownloadStates[model.name] ?? false
    }

    func isPaused(_ model: FluidAudioModel) -> Bool { downloadStates[model.name]?.phase == .paused }

    func startDownload(_ model: FluidAudioModel) {
        guard downloadTasks[model.name] == nil else { return }
        let isResuming = downloadStates[model.name]?.phase == .paused
        downloadStates[model.name] = ModelDownloadState(phase: isResuming ? .resuming : .queued)
        try? downloadStateStore.save(downloadStates[model.name]!, for: model.name)
        pausedDownloads.remove(model.name)
        cancelledDownloads.remove(model.name)
        downloadTasks[model.name] = Task { [weak self] in
            await self?.downloadFluidAudioModel(model)
            self?.downloadTasks[model.name] = nil
        }
    }

    func pauseDownload(_ model: FluidAudioModel) {
        guard downloadTasks[model.name] != nil else { return }
        pausedDownloads.insert(model.name)
        downloadTasks[model.name]?.cancel()
    }

    func resumeDownload(_ model: FluidAudioModel) {
        guard isPaused(model) else { return }
        Task { @MainActor in
            while downloadTasks[model.name] != nil { try? await Task.sleep(for: .milliseconds(20)) }
            startDownload(model)
        }
    }

    func cancelDownload(_ model: FluidAudioModel) {
        pausedDownloads.remove(model.name)
        cancelledDownloads.insert(model.name)
        downloadTasks[model.name]?.cancel()
        downloadStates[model.name] = ModelDownloadState(phase: .queued)
        try? downloadStateStore.save(downloadStates[model.name]!, for: model.name)
    }

    // MARK: - Download

    func downloadFluidAudioModel(_ model: FluidAudioModel) async {
        if !Self.isModelAvailable(model.name) || isFluidAudioModelDownloaded(model) || model.hardwareFit.blocksInstall || isFluidAudioModelDownloading(model) {
            return
        }

        let modelName = model.name
        parakeetDownloadStates[modelName] = true
        downloadProgress[modelName] = 0.0
        downloadErrors[modelName] = nil

        downloadStates[modelName] = ModelDownloadState(phase: .downloading)
        try? downloadStateStore.save(downloadStates[modelName]!, for: modelName)

        do {
            if modelName == Self.unifiedModelName {
                let manager = UnifiedAsrManager()
                let progressHandler: ProgressHandler = { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress[modelName] = progress.fractionCompleted }
                }
                try await manager.loadModels(progressHandler: progressHandler)
                await manager.cleanup()
            } else {
                let progressHandler: ProgressHandler = { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress[modelName] = progress.fractionCompleted }
                }
                _ = try await AsrModels.downloadAndLoad(version: Self.asrVersion(for: modelName), progressHandler: progressHandler)
            }
            _ = try await VadManager()

            UserDefaults.standard.set(true, forKey: parakeetDefaultsKey(for: modelName))
            downloadProgress[modelName] = 1.0
            downloadStates[modelName] = ModelDownloadState(phase: .completed, fractionCompleted: 1)
        } catch {
            if pausedDownloads.contains(modelName) {
                downloadStates[modelName] = ModelDownloadState(phase: .paused, fractionCompleted: downloadProgress[modelName])
            } else if error is CancellationError || (error as? URLError)?.code == .cancelled {
                UserDefaults.standard.set(false, forKey: parakeetDefaultsKey(for: modelName))
                if cancelledDownloads.contains(modelName) {
                    try? FileManager.default.removeItem(at: cacheDirectory(forModelNamed: modelName))
                    cancelledDownloads.remove(modelName)
                }
                downloadStates[modelName] = ModelDownloadState(phase: .queued)
            } else {
                UserDefaults.standard.set(false, forKey: parakeetDefaultsKey(for: modelName))
                downloadErrors[modelName] = error.localizedDescription
                downloadStates[modelName] = ModelDownloadState(phase: .failed, message: error.localizedDescription)
                logger.error("FluidAudio download failed for \(modelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        parakeetDownloadStates[modelName] = false
        if downloadStates[modelName]?.phase != .paused { downloadProgress[modelName] = nil }
        if let state = downloadStates[modelName] { try? downloadStateStore.save(state, for: modelName) }

        onModelsChanged?()
    }

    // MARK: - Delete

    func deleteFluidAudioModel(_ model: FluidAudioModel) {
        let cacheDirectory = cacheDirectory(forModelNamed: model.name)

        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
            UserDefaults.standard.set(false, forKey: parakeetDefaultsKey(for: model.name))
        } catch {
            logger.error("❌ Could not delete \(model.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Notify TranscriptionModelManager to clear currentTranscriptionModel if it matches
        onModelDeleted?(model.name)
    }

    // MARK: - Finder

    func showFluidAudioModelInFinder(_ model: FluidAudioModel) {
        let cacheDirectory = cacheDirectory(forModelNamed: model.name)

        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            NSWorkspace.shared.selectFile(cacheDirectory.path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: - Private helpers

    private func parakeetDefaultsKey(for modelName: String) -> String {
        "ParakeetModelDownloaded_\(modelName)"
    }

    private func cacheDirectory(forModelNamed modelName: String) -> URL {
        if modelName == Self.unifiedModelName {
            return Self.unifiedCacheDirectory
        }
        return AsrModels.defaultCacheDirectory(for: Self.asrVersion(for: modelName))
    }
}
