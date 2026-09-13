import Foundation
import os

/// Moves selections off the Gemini transcription models LLMkit no longer accepts.
///
/// LLMkit's `GeminiTranscriptionClient` now only serves the dedicated `gemini-3.5-transcribe`
/// model and throws `unsupportedModel` for anything else. A saved selection pointing at one of
/// the general-purpose Gemini ids would otherwise fail every dictation, so it is switched to the
/// dedicated model — same provider, same API key.
///
/// Safe to delete once all users have updated past this version.
enum RetiredGeminiTranscriptionMigration {
    static let completionKey = "retired-gemini-transcription-migration-completed"

    /// Every Gemini id Zerm has ever offered for transcription. Exact names only.
    static let retiredModelNames: Set<String> = [
        "gemini-3.5-flash",
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-3-flash-preview",
        "gemini-3.1-pro-preview"
    ]

    static let powerModeConfigurationsKey = "powerModeConfigurationsV2"
    static let powerModeSessionKey = "powerModeActiveSession.v1"

    /// `defaults` is injectable so tests never mark the real install as migrated.
    static func run(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completionKey) else { return }

        let logger = Logger(subsystem: "com.arcusis.zerm", category: "RetiredGeminiTranscriptionMigration")
        let replacement = GeminiProvider.transcribeModelName

        if let saved = defaults.string(forKey: "CurrentTranscriptionModel"), retiredModelNames.contains(saved) {
            defaults.set(replacement, forKey: "CurrentTranscriptionModel")
            logger.notice("Switched transcription model \(saved, privacy: .public) to \(replacement, privacy: .public)")
        }

        // Power Mode data is rewritten through JSONSerialization so the migration stays
        // independent of the PowerModeConfig and session struct shapes.
        if let data = defaults.data(forKey: powerModeConfigurationsKey),
           var configs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            var changed = false
            for index in configs.indices {
                guard let saved = configs[index]["selectedTranscriptionModelName"] as? String,
                      retiredModelNames.contains(saved) else { continue }
                configs[index]["selectedTranscriptionModelName"] = replacement
                changed = true
            }
            if changed, let newData = try? JSONSerialization.data(withJSONObject: configs) {
                defaults.set(newData, forKey: powerModeConfigurationsKey)
                logger.notice("Switched retired Gemini transcription models in Power Mode configurations")
            }
        }

        // An interrupted Power Mode session restores the model it replaced.
        if let data = defaults.data(forKey: powerModeSessionKey),
           var session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var state = session["originalState"] as? [String: Any],
           let saved = state["transcriptionModelName"] as? String,
           retiredModelNames.contains(saved) {
            state["transcriptionModelName"] = replacement
            session["originalState"] = state
            if let newData = try? JSONSerialization.data(withJSONObject: session) {
                defaults.set(newData, forKey: powerModeSessionKey)
            }
        }

        defaults.set(true, forKey: completionKey)
    }
}
