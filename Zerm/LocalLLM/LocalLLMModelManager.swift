import Foundation
import os

/// Describes a downloadable on-device LLM (a single GGUF file).
struct LocalLLMPackage: Identifiable, Hashable {
    let fileName: String
    let displayName: String
    let approxSize: String
    let downloadURL: URL

    /// `fileName` is the stable identity/key (also the on-disk name).
    var id: String { fileName }
}

/// Downloads, stores, and serves Zerm's on-device language models — the third local model
/// alongside Whisper (speech-to-text) and Kokoro (text-to-speech). Same UX as both: pick a
/// model, download it with a progress bar, then everything runs offline.
///
/// A single "current" model is shared by AI Enhancement and Read Aloud's naturalization.
@MainActor
final class LocalLLMModelManager: ObservableObject {
    static let shared = LocalLLMModelManager()

    /// The downloadable catalogue — all Google Gemma (GGUF, 4-bit Q4_K_M), spanning tiny→medium.
    /// Users pick one as the active on-device model. Add new entries here to offer more.
    static let packages: [LocalLLMPackage] = [
        LocalLLMPackage(
            fileName: "gemma-3-1b-it-Q4_K_M.gguf",
            displayName: "Gemma 3 1B (on-device)",
            approxSize: "~806 MB",
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf")!
        ),
        LocalLLMPackage(
            fileName: "gemma-4-E2B-it-Q4_K_M.gguf",
            displayName: "Gemma 4 E2B (on-device)",
            approxSize: "~3.1 GB",
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!
        ),
        LocalLLMPackage(
            fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
            displayName: "Gemma 4 E4B (on-device)",
            approxSize: "~5.0 GB",
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf")!
        ),
        LocalLLMPackage(
            fileName: "gemma-4-12b-it-Q4_K_M.gguf",
            displayName: "Gemma 4 12B (on-device)",
            approxSize: "~7.1 GB",
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf")!
        ),
        LocalLLMPackage(
            fileName: "gemma-3-27b-it-Q4_K_M.gguf",
            displayName: "Gemma 3 27B (on-device)",
            approxSize: "~16.5 GB",
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-3-27b-it-GGUF/resolve/main/gemma-3-27b-it-Q4_K_M.gguf")!
        )
    ]

    /// The shipped default (out-of-box) model.
    static let defaultPackage = packages.first { $0.fileName == "gemma-4-E2B-it-Q4_K_M.gguf" } ?? packages[1]

    private static let currentModelKey = "CurrentLocalLLMModel"

    /// The currently-selected on-device model (shared by Enhancement + Read Aloud).
    nonisolated static var current: LocalLLMPackage {
        let saved = UserDefaults.standard.string(forKey: currentModelKey)
        return packages.first { $0.fileName == saved } ?? defaultPackage
    }

    /// Backward-compatible alias for the many call sites that referenced the single package;
    /// it now resolves to the currently-selected model.
    nonisolated static var package: LocalLLMPackage { current }

    @Published private(set) var installedFiles: Set<String> = []
    /// Per-model download progress (0.0–1.0), keyed by fileName; absent when not downloading.
    @Published private(set) var downloadProgress: [String: Double] = [:]
    /// Mirrors the persisted current-model selection so SwiftUI updates on change.
    @Published private(set) var currentFileName: String = LocalLLMModelManager.current.fileName
    @Published private(set) var statusText: String?

    let modelsDirectory: URL
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "LocalLLMModelManager")
    private var engine: LlamaEngine?
    private var engineFileName: String?
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
        modelsDirectory = appSupport.appendingPathComponent("LLMModels")
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        refreshInstalled()
    }

    // MARK: - Paths & state

    func path(for package: LocalLLMPackage) -> URL { modelsDirectory.appendingPathComponent(package.fileName) }

    var currentPackage: LocalLLMPackage { Self.current }

    /// Path of the currently-selected model (kept for backward compatibility).
    var modelPath: URL { path(for: currentPackage) }

    func refreshInstalled() {
        var set = Set<String>()
        for package in Self.packages where FileManager.default.fileExists(atPath: path(for: package).path) {
            set.insert(package.fileName)
        }
        installedFiles = set
    }

    func isDownloaded(_ package: LocalLLMPackage) -> Bool { installedFiles.contains(package.fileName) }
    func isDownloading(_ package: LocalLLMPackage) -> Bool { downloadProgress[package.fileName] != nil }

    /// True when the *current* model is downloaded (backward-compatible single-model check).
    var isInstalled: Bool { isDownloaded(currentPackage) }

    /// Thread-safe install check for the current model, usable from non-main contexts (e.g. `AIService`).
    nonisolated static var isModelDownloaded: Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
        let path = appSupport.appendingPathComponent("LLMModels")
            .appendingPathComponent(current.fileName).path
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Selection

    /// Switch the active on-device model. Unloads the previous engine so the next generation
    /// loads the newly-selected weights.
    func select(_ package: LocalLLMPackage) {
        guard package.fileName != currentFileName else { return }
        UserDefaults.standard.set(package.fileName, forKey: Self.currentModelKey)
        currentFileName = package.fileName
        if engineFileName != package.fileName {
            engine = nil
            engineFileName = nil
        }
    }

    // MARK: - Download

    func download(_ package: LocalLLMPackage) async {
        guard downloadProgress[package.fileName] == nil else { return }
        downloadProgress[package.fileName] = 0
        statusText = nil
        defer { downloadProgress[package.fileName] = nil }

        do {
            let file = try await downloadFile(for: package)
            let dest = path(for: package)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: file, to: dest)
            refreshInstalled()
        } catch is CancellationError {
            statusText = "Download cancelled"
        } catch {
            logger.error("LLM download failed: \(error.localizedDescription, privacy: .public)")
            statusText = "Download failed: \(error.localizedDescription)"
        }
    }

    /// Downloads the current model (backward-compatible no-arg form).
    func download() async { await download(currentPackage) }

    func cancelDownload(_ package: LocalLLMPackage) {
        downloadTasks[package.fileName]?.cancel()
        downloadTasks[package.fileName] = nil
    }

    func delete(_ package: LocalLLMPackage) {
        if engineFileName == package.fileName { engine = nil; engineFileName = nil }
        try? FileManager.default.removeItem(at: path(for: package))
        refreshInstalled()
    }

    /// Deletes the current model (backward-compatible no-arg form).
    func delete() { delete(currentPackage) }

    /// Release the warm engine so it doesn't pin GB of RAM after idle.
    func unloadIfIdle() {
        guard engine != nil else { return }
        logger.notice("Unloading local LLM engine (idle / memory reclaim)")
        engine = nil
        engineFileName = nil
    }

    /// Downloads to a temp file, reporting fractional progress via KVO (mirrors KokoroModelManager).
    private func downloadFile(for package: LocalLLMPackage) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: package.downloadURL) { [weak self] tempURL, response, error in
                Task { @MainActor [weak self] in
                    self?.progressObservations[package.fileName]?.invalidate()
                    self?.progressObservations[package.fileName] = nil
                    self?.downloadTasks[package.fileName] = nil
                }
                if let error { continuation.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continuation.resume(throwing: TTSError.http((response as? HTTPURLResponse)?.statusCode ?? -1, "download failed"))
                    return
                }
                guard let tempURL else { continuation.resume(throwing: TTSError.badResponse); return }
                do {
                    let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("llm-download-\(package.fileName)")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            self.downloadTasks[package.fileName] = task
            self.progressObservations[package.fileName] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in self?.downloadProgress[package.fileName] = progress.fractionCompleted }
            }
            task.resume()
        }
    }

    // MARK: - Generation

    /// Rewrites/answers using the current on-device model. Loads it on first use.
    func generate(system: String, user: String, maxNewTokens: Int = 400,
                  isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> String {
        guard isInstalled else {
            throw TTSError.notAvailable("The on-device model isn't downloaded yet. Download it in Enhancement or Read Aloud settings.")
        }
        let engine = ensureEngine()
        return try await engine.generate(system: system, user: user, maxNewTokens: maxNewTokens, isCancelled: isCancelled)
    }

    /// Pre-loads the current model in the background so the first natural read is fast.
    func prewarmIfNeeded() async {
        guard isInstalled, TTSSettings.naturalReadingAI else { return }
        let engine = ensureEngine()
        try? await engine.warmUp()
    }

    private func ensureEngine() -> LlamaEngine {
        if let engine, engineFileName == currentPackage.fileName { return engine }
        let engine = LlamaEngine(modelPath: modelPath.path)
        self.engine = engine
        self.engineFileName = currentPackage.fileName
        return engine
    }
}
