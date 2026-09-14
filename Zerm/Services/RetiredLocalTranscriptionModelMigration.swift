import Foundation
import FluidAudio
import os

/// Moves selections off the local speech models removed in 2.8.6 and deletes their files.
///
/// Whisper tiny/base/small (and their `.en` variants) are outclassed by the current catalog, and
/// Parakeet v2 is replaced by Parakeet Unified. Each saved selection — the default model, every
/// Power Mode configuration and an interrupted Power Mode session — moves to the closest
/// replacement. Nothing is downloaded here: if the replacement is not on disk yet, the Models
/// screen shows it as "download required". Files are deleted only after the selections were
/// rewritten, and the migration retries on the next launch if a deletion fails.
///
/// Safe to delete once all users have updated past this version.
enum RetiredLocalTranscriptionModelMigration {
    static let completionKey = "retired-local-transcription-models-migration-v1"
    /// Set when the default model was replaced; the Models screen shows a one-time notice.
    static let replacementNoticeKey = "retired-local-transcription-model-replacement"
    static let noticeRetiredNameKey = "retired"
    static let noticeReplacementNameKey = "replacement"

    static let parakeetV2ModelName = "parakeet-tdt-0.6b-v2"
    static let retiredEnglishWhisperModelNames: Set<String> = ["ggml-tiny.en", "ggml-base.en", "ggml-small.en"]
    static let retiredMultilingualWhisperModelNames: Set<String> = ["ggml-tiny", "ggml-base", "ggml-small"]

    /// Names the retired models were listed under, for the replacement notice.
    static let retiredDisplayNames: [String: String] = [
        "ggml-tiny": "Whisper Tiny",
        "ggml-tiny.en": "Whisper Tiny (English)",
        "ggml-base": "Whisper Base",
        "ggml-base.en": "Whisper Base (English)",
        "ggml-small": "Whisper Small",
        "ggml-small.en": "Whisper Small (English)",
        "parakeet-tdt-0.6b-v2": "Parakeet V2"
    ]

    static var retiredModelNames: Set<String> {
        retiredEnglishWhisperModelNames
            .union(retiredMultilingualWhisperModelNames)
            .union([parakeetV2ModelName])
    }

    static let powerModeConfigurationsKey = "powerModeConfigurationsV2"
    static let powerModeSessionKey = "powerModeActiveSession.v1"

    /// The closest current model for a retired one. English-only Whisper moves to Parakeet
    /// Unified where FluidAudio runs (Apple Silicon); everything else to Large v3 Turbo (Quantized).
    static func replacement(for retiredName: String, isAppleSilicon: Bool) -> String? {
        let unified = FluidAudioModelManager.unifiedModelName
        let turboQuantized = "ggml-large-v3-turbo-q5_0"
        if retiredName == parakeetV2ModelName { return unified }
        if retiredEnglishWhisperModelNames.contains(retiredName) { return isAppleSilicon ? unified : turboQuantized }
        if retiredMultilingualWhisperModelNames.contains(retiredName) { return turboQuantized }
        return nil
    }

    /// Everything is injectable so tests never touch the real install's defaults or model files.
    static func run(
        defaults: UserDefaults = .standard,
        isAppleSilicon: Bool = SystemArchitecture.isAppleSilicon,
        whisperModelsDirectory: URL,
        parakeetV2CacheDirectory: URL = AsrModels.defaultCacheDirectory(for: .v2),
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: completionKey) else { return }

        let logger = Logger(subsystem: "com.arcusis.zerm", category: "RetiredLocalTranscriptionModelMigration")
        func replacing(_ name: String?) -> String? {
            name.flatMap { replacement(for: $0, isAppleSilicon: isAppleSilicon) }
        }

        if let saved = defaults.string(forKey: "CurrentTranscriptionModel"), let replacement = replacing(saved) {
            defaults.set(replacement, forKey: "CurrentTranscriptionModel")
            defaults.set(
                [noticeRetiredNameKey: saved, noticeReplacementNameKey: replacement],
                forKey: replacementNoticeKey
            )
            logger.notice("Switched transcription model \(saved, privacy: .public) to \(replacement, privacy: .public)")
        }

        // Power Mode data is rewritten through JSONSerialization so the migration stays
        // independent of the PowerModeConfig and session struct shapes.
        if let data = defaults.data(forKey: powerModeConfigurationsKey),
           var configs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            var changed = false
            for index in configs.indices {
                guard let replacement = replacing(configs[index]["selectedTranscriptionModelName"] as? String) else { continue }
                configs[index]["selectedTranscriptionModelName"] = replacement
                changed = true
            }
            if changed, let newData = try? JSONSerialization.data(withJSONObject: configs) {
                defaults.set(newData, forKey: powerModeConfigurationsKey)
                logger.notice("Switched retired local models in Power Mode configurations")
            }
        }

        // An interrupted Power Mode session restores the model it replaced.
        if let data = defaults.data(forKey: powerModeSessionKey),
           var session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var state = session["originalState"] as? [String: Any],
           let replacement = replacing(state["transcriptionModelName"] as? String) {
            state["transcriptionModelName"] = replacement
            session["originalState"] = state
            if let newData = try? JSONSerialization.data(withJSONObject: session) {
                defaults.set(newData, forKey: powerModeSessionKey)
            }
        }

        defaults.removeObject(forKey: "ParakeetModelDownloaded_\(parakeetV2ModelName)")
        defaults.removeObject(forKey: "streaming-enabled-\(parakeetV2ModelName)")

        // Selections are safe; now reclaim the disk space.
        var leftovers: [URL] = []
        for name in retiredEnglishWhisperModelNames.union(retiredMultilingualWhisperModelNames) {
            leftovers.append(whisperModelsDirectory.appendingPathComponent("\(name).bin"))
            leftovers.append(whisperModelsDirectory.appendingPathComponent("\(name)-encoder.mlmodelc"))
        }
        leftovers.append(parakeetV2CacheDirectory)

        var allDeleted = true
        for url in leftovers where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                allDeleted = false
                logger.error("Could not delete retired model file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if allDeleted {
            defaults.set(true, forKey: completionKey)
        }
    }
}
