import Foundation

/// Single source of truth for SelectedLanguage normalization across engines.
enum LanguagePreference {
    /// Per-operation override used by long-running jobs that snapshot settings at creation.
    /// Task-local scope avoids mutating global defaults while another dictation is running.
    @TaskLocal static var operationOverrideCode: String?

    static let defaultsKey = "SelectedLanguage"

    /// The stored value meaning "let the engine detect the language".
    static let autoCode = "auto"

    /// Raw stored value (`"auto"`, `"en"`, …).
    static func selectedCode(defaults: UserDefaults = .standard) -> String {
        if let operationOverrideCode, !operationOverrideCode.isEmpty {
            return operationOverrideCode
        }
        let raw = defaults.string(forKey: defaultsKey) ?? "auto"
        return raw.isEmpty ? "auto" : raw
    }

    /// `nil` when auto-detect; otherwise the language code for APIs that omit param = auto.
    static func apiLanguage(defaults: UserDefaults = .standard) -> String? {
        let code = selectedCode(defaults: defaults)
        if code == "auto" || code.isEmpty { return nil }
        return code
    }

    /// True when the user wants automatic language detection.
    static func isAuto(defaults: UserDefaults = .standard) -> Bool {
        apiLanguage(defaults: defaults) == nil
    }
}

/// Process-wide "we are shutting down (or must not start native work)" flag.
///
/// Native ML runtimes (onnxruntime via sherpa-onnx, llama.cpp) read C++ global registries while
/// constructing a session. If `exit()` runs concurrently, `__cxa_finalize_ranges` tears those
/// globals down mid-construction and the load segfaults. None of that work is cancellable once
/// it has entered the C++ library, so background prewarm tasks check this before starting.
enum ProcessLifecycle {
    nonisolated(unsafe) static var isTerminating = false
}
