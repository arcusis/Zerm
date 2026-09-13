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

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "FluidAudioModelManager")

    // Add new Fluid Audio TDT models here when support is added.
    nonisolated static let modelVersionMap: [String: AsrModelVersion] = [
        "parakeet-tdt-ctc-110m": .tdtCtc110m,
        "parakeet-tdt-0.6b-v3": .v3,
    ]

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

    init() {}

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

    // MARK: - Download

    func downloadFluidAudioModel(_ model: FluidAudioModel) async {
        if isFluidAudioModelDownloaded(model) || model.hardwareFit.blocksInstall || isFluidAudioModelDownloading(model) {
            return
        }

        let modelName = model.name
        parakeetDownloadStates[modelName] = true
        downloadProgress[modelName] = 0.0
        downloadErrors[modelName] = nil

        let timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { timer in
            Task { @MainActor in
                if let currentProgress = self.downloadProgress[modelName], currentProgress < 0.9 {
                    self.downloadProgress[modelName] = currentProgress + 0.005
                }
            }
        }

        do {
            if modelName == Self.unifiedModelName {
                let manager = UnifiedAsrManager()
                try await manager.loadModels()
                await manager.cleanup()
            } else {
                _ = try await AsrModels.downloadAndLoad(version: Self.asrVersion(for: modelName))
            }
            _ = try await VadManager()

            UserDefaults.standard.set(true, forKey: parakeetDefaultsKey(for: modelName))
            downloadProgress[modelName] = 1.0
        } catch {
            UserDefaults.standard.set(false, forKey: parakeetDefaultsKey(for: modelName))
            downloadErrors[modelName] = error.localizedDescription
            logger.error("❌ FluidAudio download failed for \(modelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        timer.invalidate()
        parakeetDownloadStates[modelName] = false
        downloadProgress[modelName] = nil

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
