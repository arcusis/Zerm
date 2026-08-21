import Foundation
import os

/// Retires the on-device models that measurement disqualified, and releases the disk they hold.
///
/// Against the shipped enhancement prompt over a 20-case dictation set, run three times each:
///
/// - **Qwen3 1.7B** — 6/20. Echoed the prompt's own `<TRANSCRIPT>` scaffolding back into the
///   output in 18–19 of 20 cases, handled 0/4 spoken self-corrections, and translated mixed
///   Hebrew/English instead of preserving it. It was also the model whose `<think>` opener made
///   every enhancement return an empty string (#307).
/// - **Qwen3 0.6B** — 3/20, with 3 outright empty results and scaffolding leaked in all 20.
/// - **Qwen3 4B** — removed with the rest of the family; it shares their behaviour and was never
///   the default.
/// - **Gemma 4 E2B (legacy Q4_K_M quant)** — produced nothing at all in 9 of 20 cases. The
///   `q4_0` QAT build of the same model scores 12–14/20 with zero failures.
///
/// A selection pointing at a retired model would otherwise resolve through the fallback chain on
/// every launch, which works but silently contradicts what Settings shows. The weights are also
/// deleted: they live in Zerm's own `LLMModels` directory, they are between 0.4 GB and 3.1 GB
/// each, and nothing in the app can load them again now that they are off the catalogue.
///
/// Safe to delete once all users have updated past this version.
enum RetiredLocalLLMMigration {
    static let completionKey = "retired-local-llm-migration-completed"

    /// Exact file names only — never a prefix or pattern, so a future catalogue entry that
    /// happens to share a name fragment can never be swept up by this.
    static let retiredFileNames: Set<String> = [
        "Qwen3-1.7B-Q4_K_M.gguf",
        "Qwen3-0.6B-Q4_K_M.gguf",
        "Qwen3-4B-Q4_K_M.gguf",
        "gemma-4-E2B-it-Q4_K_M.gguf"
    ]

    /// `defaults` and `modelsDirectory` are injectable so tests never mark the real install as
    /// migrated, and never delete the user's actual model files.
    static func run(defaults: UserDefaults = .standard, modelsDirectory: URL? = nil) {
        guard !defaults.bool(forKey: completionKey) else { return }

        let logger = Logger(subsystem: "com.arcusis.zerm", category: "RetiredLocalLLMMigration")

        // Clear a selection that points at a retired model so Settings and the resolver agree.
        for key in ["CurrentLocalLLMModel", LocalLLMModelManager.enhancementModelKey] {
            if let selected = defaults.string(forKey: key), retiredFileNames.contains(selected) {
                defaults.removeObject(forKey: key)
                logger.notice("Cleared retired on-device model selection for \(key, privacy: .public)")
            }
        }

        let modelsDirectory = modelsDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
            .appendingPathComponent("LLMModels")

        var reclaimedBytes: Int64 = 0
        for fileName in retiredFileNames {
            let url = modelsDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
                .flatMap { $0[.size] as? Int64 } ?? 0
            do {
                try FileManager.default.removeItem(at: url)
                reclaimedBytes += size
                logger.notice("Removed retired on-device model \(fileName, privacy: .public)")
            } catch {
                logger.error("Could not remove \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if reclaimedBytes > 0 {
            let gb = Double(reclaimedBytes) / 1_073_741_824
            logger.notice("Reclaimed \(String(format: "%.2f", gb), privacy: .public) GB from retired on-device models")
        }

        defaults.set(true, forKey: completionKey)
    }
}
