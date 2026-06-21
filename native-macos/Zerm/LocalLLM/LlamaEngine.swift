import Foundation
import os

/// Serializes on-device LLM inference off the main thread — the LLM counterpart of
/// `KokoroEngine`. The actual llama.cpp work lives in `LlamaBridge` (Objective-C++) so the
/// llama/ggml headers never reach Swift (they would clash with whisper.cpp's vendored ggml).
actor LlamaEngine {
    enum LlamaError: LocalizedError {
        case loadFailed, generateFailed
        var errorDescription: String? {
            switch self {
            case .loadFailed: return "Failed to load the on-device model."
            case .generateFailed: return "On-device generation failed."
            }
        }
    }

    private let bridge: LlamaBridge

    init(modelPath: String) {
        bridge = LlamaBridge(modelPath: modelPath)
    }

    /// Loads the model without generating, so the first real request is fast.
    func warmUp() throws {
        guard bridge.load() else { throw LlamaError.loadFailed }
    }

    /// Runs one instruction-style generation. `isCancelled` is polled between tokens.
    func generate(system: String, user: String, maxNewTokens: Int = 400,
                  isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> String {
        guard let result = bridge.generate(withSystem: system, user: user,
                                           maxNewTokens: Int32(maxNewTokens),
                                           isCancelled: { isCancelled() }) else {
            throw LlamaError.generateFailed
        }
        return result
    }
}
