import Foundation
import FluidAudio
import AppKit
import os

@MainActor
class FluidAudioModelManager: ObservableObject {
    @Published var parakeetDownloadStates: [String: Bool] = [:]
    @Published var downloadProgress: [String: Double] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "FluidAudioModelManager")

    // Add new Fluid Audio models here when support is added.
    static let modelVersionMap: [String: AsrModelVersion] = [
        "parakeet-tdt-0.6b-v2": .v2,
        "parakeet-tdt-0.6b-v3": .v3,
    ]

    nonisolated static func asrVersion(for modelName: String) -> AsrModelVersion {
        modelVersionMap[modelName] ?? .v3
    }

    init() {}

    // MARK: - Query helpers

    func isFluidAudioModelDownloaded(named modelName: String) -> Bool {
        UserDefaults.standard.bool(forKey: parakeetDefaultsKey(for: modelName))
    }

    func isFluidAudioModelDownloaded(_ model: FluidAudioModel) -> Bool {
        isFluidAudioModelDownloaded(named: model.name)
    }

    func isFluidAudioModelDownloading(_ model: FluidAudioModel) -> Bool {
        parakeetDownloadStates[model.name] ?? false
    }

    // MARK: - Download

    func downloadFluidAudioModel(_ model: FluidAudioModel) async {
        if isFluidAudioModelDownloaded(model) {
            return
        }

        let modelName = model.name
        parakeetDownloadStates[modelName] = true
        downloadProgress[modelName] = 0.0

        let timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { timer in
            Task { @MainActor in
                if let currentProgress = self.downloadProgress[modelName], currentProgress < 0.9 {
                    self.downloadProgress[modelName] = currentProgress + 0.005
                }
            }
        }

        let version = FluidAudioModelManager.asrVersion(for: modelName)

        do {
            _ = try await AsrModels.downloadAndLoad(version: version)
            _ = try await VadManager()

            UserDefaults.standard.set(true, forKey: parakeetDefaultsKey(for: modelName))
            downloadProgress[modelName] = 1.0
        } catch {
            UserDefaults.standard.set(false, forKey: parakeetDefaultsKey(for: modelName))
            logger.error("❌ FluidAudio download failed for \(modelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        timer.invalidate()
        parakeetDownloadStates[modelName] = false
        downloadProgress[modelName] = nil

        onModelsChanged?()
    }

    // MARK: - Delete

    func deleteFluidAudioModel(_ model: FluidAudioModel) {
        let version = FluidAudioModelManager.asrVersion(for: model.name)
        let cacheDirectory = parakeetCacheDirectory(for: version)

        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
            UserDefaults.standard.set(false, forKey: parakeetDefaultsKey(for: model.name))
        } catch {
            // Silently ignore removal errors
        }

        // Notify TranscriptionModelManager to clear currentTranscriptionModel if it matches
        onModelDeleted?(model.name)
    }

    // MARK: - Finder

    func showFluidAudioModelInFinder(_ model: FluidAudioModel) {
        let cacheDirectory = parakeetCacheDirectory(for: FluidAudioModelManager.asrVersion(for: model.name))

        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            NSWorkspace.shared.selectFile(cacheDirectory.path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: - Private helpers

    private func parakeetDefaultsKey(for modelName: String) -> String {
        "ParakeetModelDownloaded_\(modelName)"
    }

    private func parakeetCacheDirectory(for version: AsrModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version)
    }
}
