import Foundation
import FluidAudio
import os.log

/// Batch transcription with Parakeet Unified 0.6B (English, punctuated). FluidAudio's
/// `UnifiedAsrManager` windows long audio itself, so a recording is decoded in one call.
class ParakeetUnifiedTranscriptionService: TranscriptionService {
    private var manager: UnifiedAsrManager?
    private let logger = Logger(subsystem: "com.arcusis.zerm.fluidaudio", category: "ParakeetUnifiedTranscriptionService")

    enum ServiceError: Error, LocalizedError {
        case modelNotDownloaded

        var errorDescription: String? {
            switch self {
            case .modelNotDownloaded:
                return String(localized: "Parakeet Unified is not downloaded. Download it again in Models.")
            }
        }
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let samples = try await AudioProcessor().processAudioToSamples(audioURL)
        let manager = try await loadedManager()

        do {
            return try await manager.transcribe(samples)
        } catch {
            // Core ML handles can go stale after the app sits idle and memory is paged out
            // (VoiceInk #614). Reload from disk once and retry.
            logger.notice("Unified prediction failed; reloading models and retrying once: \(error.localizedDescription, privacy: .public)")
            await manager.cleanup()
            self.manager = nil
            return try await loadedManager().transcribe(samples)
        }
    }

    /// Loads from the local cache only; downloading happens in the Models screen.
    private func loadedManager() async throws -> UnifiedAsrManager {
        if let manager { return manager }

        let directory = FluidAudioModelManager.unifiedCacheDirectory
        let filesPresent = FluidAudioModelManager.unifiedRequiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard filesPresent else { throw ServiceError.modelNotDownloaded }

        let manager = UnifiedAsrManager()
        do {
            try await manager.loadModels(from: directory)
        } catch {
            logger.error("❌ Parakeet Unified failed to load: \(error.localizedDescription, privacy: .public)")
            throw ZermEngineError.modelLoadFailed
        }
        self.manager = manager
        return manager
    }
}
