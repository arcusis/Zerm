import Foundation
import os

/// Describes the downloadable on-device LLM (a single GGUF file).
struct LocalLLMPackage {
    let fileName: String
    let displayName: String
    let approxSize: String
    let downloadURL: URL
}

/// Downloads, stores, and serves Zerm's on-device language model — the third local model
/// alongside Whisper (speech-to-text) and Kokoro (text-to-speech). Same UX as both: first
/// use auto-downloads with a progress bar, then everything runs offline.
///
/// Powers Read Aloud's "Natural reading" rewrite today; reusable for local AI Enhancement.
@MainActor
final class LocalLLMModelManager: ObservableObject {
    static let shared = LocalLLMModelManager()

    /// Gemma 4 E2B Instruct, 4-bit (Q4_K_M) — the smallest/latest Gemma, on-device optimized
    /// (Per-Layer Embeddings). The default "agentic" model powering both AI Enhancement and
    /// Read Aloud naturalization. Users can swap in other GGUF models (see model management).
    static let package = LocalLLMPackage(
        fileName: "gemma-4-E2B-it-Q4_K_M.gguf",
        displayName: "Gemma 4 E2B (on-device)",
        approxSize: "~3.1 GB",
        downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!
    )

    @Published private(set) var isInstalled = false
    @Published private(set) var isDownloading = false
    /// 0.0–1.0 while downloading; nil when idle.
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var statusText: String?

    let modelsDirectory: URL
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "LocalLLMModelManager")
    private var engine: LlamaEngine?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
        modelsDirectory = appSupport.appendingPathComponent("LLMModels")
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        refreshInstalled()
    }

    // MARK: - Paths

    var modelPath: URL { modelsDirectory.appendingPathComponent(Self.package.fileName) }

    func refreshInstalled() {
        isInstalled = FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Thread-safe install check usable from non-main contexts (e.g. `AIService`).
    nonisolated static var isModelDownloaded: Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
        let path = appSupport.appendingPathComponent("LLMModels")
            .appendingPathComponent(package.fileName).path
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Download

    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        statusText = "Downloading reading model…"
        defer { isDownloading = false; downloadProgress = nil }

        do {
            let file = try await downloadFile(from: Self.package.downloadURL)
            try? FileManager.default.removeItem(at: modelPath)
            try FileManager.default.moveItem(at: file, to: modelPath)
            refreshInstalled()
            statusText = isInstalled ? nil : "Download incomplete"
        } catch is CancellationError {
            statusText = "Download cancelled"
        } catch {
            logger.error("LLM download failed: \(error.localizedDescription, privacy: .public)")
            statusText = "Download failed: \(error.localizedDescription)"
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    func delete() {
        engine = nil
        try? FileManager.default.removeItem(at: modelPath)
        refreshInstalled()
    }

    /// Downloads to a temp file, reporting fractional progress via KVO (mirrors KokoroModelManager).
    private func downloadFile(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
                self?.progressObservation?.invalidate()
                self?.progressObservation = nil
                if let error { continuation.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continuation.resume(throwing: TTSError.http((response as? HTTPURLResponse)?.statusCode ?? -1, "download failed"))
                    return
                }
                guard let tempURL else { continuation.resume(throwing: TTSError.badResponse); return }
                do {
                    let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("llm-download-\(Self.package.fileName)")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            self.downloadTask = task
            self.progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in self?.downloadProgress = progress.fractionCompleted }
            }
            task.resume()
        }
    }

    // MARK: - Generation

    /// Rewrites/answers using the on-device model. Loads it on first use.
    func generate(system: String, user: String, maxNewTokens: Int = 400,
                  isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> String {
        guard isInstalled else {
            throw TTSError.notAvailable("The on-device reading model isn't downloaded yet. Download it in Read Aloud settings.")
        }
        let engine = ensureEngine()
        return try await engine.generate(system: system, user: user, maxNewTokens: maxNewTokens, isCancelled: isCancelled)
    }

    /// Pre-loads the model in the background so the first natural read is fast.
    func prewarmIfNeeded() async {
        guard isInstalled, TTSSettings.naturalReadingAI else { return }
        let engine = ensureEngine()
        try? await engine.warmUp()
    }

    private func ensureEngine() -> LlamaEngine {
        if let engine { return engine }
        let engine = LlamaEngine(modelPath: modelPath.path)
        self.engine = engine
        return engine
    }
}
