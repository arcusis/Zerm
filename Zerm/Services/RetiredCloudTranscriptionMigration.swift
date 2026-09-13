import Foundation
import os

/// Moves selections off cloud transcription model ids that were renamed or retired.
///
/// - LLMkit's `GeminiTranscriptionClient` only serves the dedicated `gemini-3.5-transcribe` model
///   and throws `unsupportedModel` for the general-purpose Gemini ids.
/// - OpenAI deprecated the gpt-4o transcription models on 2026-08-26 in favour of `gpt-transcribe`.
/// - Mistral's batch transcription model is now pinned as `voxtral-mini-2602`.
///
/// A saved selection pointing at one of these would otherwise fail every dictation or vanish from
/// the Models screen, so it is switched to the replacement — same provider, same API key.
///
/// Safe to delete once all users have updated past this version.
enum RetiredCloudTranscriptionMigration {
    static let completionKey = "retired-cloud-transcription-migration-completed"

    /// Every retired cloud id Zerm has offered for transcription, mapped to its replacement.
    /// Exact names only.
    static let replacements: [String: String] = [
        "gemini-3.5-flash": GeminiProvider.transcribeModelName,
        "gemini-2.5-pro": GeminiProvider.transcribeModelName,
        "gemini-2.5-flash": GeminiProvider.transcribeModelName,
        "gemini-3-flash-preview": GeminiProvider.transcribeModelName,
        "gemini-3.1-pro-preview": GeminiProvider.transcribeModelName,
        "gpt-4o-transcribe": OpenAIProvider.transcribeModelName,
        "gpt-4o-mini-transcribe": OpenAIProvider.transcribeModelName,
        "voxtral-mini-latest": MistralProvider.transcribeModelName
    ]

    static let powerModeConfigurationsKey = "powerModeConfigurationsV2"
    static let powerModeSessionKey = "powerModeActiveSession.v1"

    /// `defaults` is injectable so tests never mark the real install as migrated.
    static func run(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completionKey) else { return }

        let logger = Logger(subsystem: "com.arcusis.zerm", category: "RetiredCloudTranscriptionMigration")

        if let saved = defaults.string(forKey: "CurrentTranscriptionModel"), let replacement = replacements[saved] {
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
                      let replacement = replacements[saved] else { continue }
                configs[index]["selectedTranscriptionModelName"] = replacement
                changed = true
            }
            if changed, let newData = try? JSONSerialization.data(withJSONObject: configs) {
                defaults.set(newData, forKey: powerModeConfigurationsKey)
                logger.notice("Switched retired cloud transcription models in Power Mode configurations")
            }
        }

        // An interrupted Power Mode session restores the model it replaced.
        if let data = defaults.data(forKey: powerModeSessionKey),
           var session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var state = session["originalState"] as? [String: Any],
           let saved = state["transcriptionModelName"] as? String,
           let replacement = replacements[saved] {
            state["transcriptionModelName"] = replacement
            session["originalState"] = state
            if let newData = try? JSONSerialization.data(withJSONObject: session) {
                defaults.set(newData, forKey: powerModeSessionKey)
            }
        }

        defaults.set(true, forKey: completionKey)
    }
}
