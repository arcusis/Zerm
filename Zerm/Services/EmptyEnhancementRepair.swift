import Foundation
import SwiftData
import os

/// One-time repair for records written by 2.8.3, where every on-device enhancement was stored
/// as an empty string.
///
/// The bridge truncated generation at the `<think>` tag that Qwen3 opens its turn with, so the
/// provider returned `""` for every request. The pipeline stored that verbatim, and History
/// renders the enhancement in preference to the transcript — so the row drew a blank line over
/// text that was still fully intact in `text`.
///
/// Clearing the empty value restores the transcript in the UI for every affected record. No
/// transcript content is written or deleted; only a meaningless `""` becomes `nil`.
///
/// Safe to delete once all users have updated past this version.
enum EmptyEnhancementRepair {
    static let completionKey = "empty-enhancement-repair-completed"

    /// `defaults` is injectable so tests never mark the real install as already repaired —
    /// which would silently skip the repair on the machine the defect actually happened on.
    static func run(modelContext: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completionKey) else { return }

        let logger = Logger(subsystem: "com.arcusis.zerm", category: "EmptyEnhancementRepair")

        do {
            // `enhancedText != nil` is not expressible against an optional in a #Predicate here,
            // so the emptiness test is done in Swift over the fetched records.
            let records = try modelContext.fetch(FetchDescriptor<Transcription>())
            var repaired = 0
            for record in records {
                guard let enhanced = record.enhancedText,
                      enhanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                record.enhancedText = nil
                repaired += 1
            }

            if repaired > 0 {
                try modelContext.save()
                logger.notice("Restored \(repaired, privacy: .public) History row(s) blanked by an empty enhancement")
            }
            defaults.set(true, forKey: completionKey)
        } catch {
            // Leave the flag unset so the repair is retried on the next launch.
            logger.error("Could not repair blank History rows: \(error.localizedDescription, privacy: .public)")
        }
    }
}
