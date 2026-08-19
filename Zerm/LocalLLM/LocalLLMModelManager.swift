import Foundation
import os

/// Describes a downloadable on-device LLM (a single GGUF file).
struct LocalLLMPackage: Identifiable, Hashable, Sendable {
    let fileName: String
    let displayName: String
    let approxSize: String
    /// Rough peak RAM (GB) while generating: weights + KV cache + runtime overhead.
    let estimatedRAMGB: Double
    let downloadURL: URL
    /// Pinned SHA-256 of the GGUF at the revision in `downloadURL`, verified after download.
    let sha256: String
    /// Which jobs this package is offered for.
    let jobs: Set<LocalLLMRole>
    let blurb: String

    /// Set only for models whose chat template actually carries an `enable_thinking` switch.
    ///
    /// `LlamaBridge` then pre-fills an empty `<think></think>` block into the assistant turn,
    /// which is the only mechanism those templates honour. This is deliberately not inferred
    /// from the file name: Qwen3-4B-Instruct-2507 is a Qwen3 build with no thinking mode, and
    /// prefilling one would push tokens its template never expects.
    var disablesThinking: Bool = false

    /// `fileName` is the stable identity/key (also the on-disk name).
    var id: String { fileName }
}

/// On-device jobs that used to share one weights file. Enhancement is a 20-word
/// cleanup and has to be instant. Read Aloud is a longer rewrite and can wait.
enum LocalLLMRole: String, Sendable, Hashable {
    case enhancement
    case reading

    var title: String {
        switch self {
        case .enhancement: return "Enhancement"
        case .reading: return "Read Aloud"
        }
    }

    var jobDescription: String {
        switch self {
        case .enhancement:
            return "Cleans the transcript after dictation. Must stay instant. Do not use a chatbot."
        case .reading:
            return "Retells selected text before it is spoken. Can be a larger model."
        }
    }
}

/// Downloads, stores, and serves Zerm's on-device language models — the third local model
/// alongside Whisper (speech-to-text) and Kokoro (text-to-speech). Same UX as both: pick a
/// model, download it with a progress bar, then everything runs offline.
///
/// Enhancement and Read Aloud each pick their own package. Both default to Gemma 4 E2B: it is
/// the only catalogue model measured to leave mixed-language dictation in its original script.
@MainActor
final class LocalLLMModelManager: ObservableObject {
    static let shared = LocalLLMModelManager()

    /// The downloadable catalogue. The memory-efficient official Google QAT build is the default;
    /// larger and legacy community quantizations remain explicit user choices.
    nonisolated static let packages: [LocalLLMPackage] = [
        LocalLLMPackage(
            fileName: "gemma-4-E2B_q4_0-it.gguf",
            displayName: "Gemma 4 E2B",
            approxSize: "~3.35 GB",
            estimatedRAMGB: 4.0,
            downloadURL: URL(string: "https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/675cff42a74c774d6cb76f76d8eacb49b48c9b93/gemma-4-E2B_q4_0-it.gguf")!,
            sha256: "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634",
            jobs: [.enhancement, .reading],
            blurb: "Default for both jobs. The only catalogue model that leaves mixed-language dictation in its original script."
        ),
        LocalLLMPackage(
            fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            displayName: "Qwen3 4B Instruct",
            approxSize: "~2.5 GB",
            estimatedRAMGB: 3.2,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
            jobs: [.enhancement],
            blurb: "Smaller opt-in. Matches the default on English cleanup, but translates mixed-language dictation instead of preserving it."
        ),
        LocalLLMPackage(
            fileName: "gemma-3-1b-it-Q4_K_M.gguf",
            displayName: "Gemma 3 1B",
            approxSize: "~806 MB",
            estimatedRAMGB: 1.5,
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/f0b45be0aac41bd6a100a4b5734cad5f67255bfb/gemma-3-1b-it-Q4_K_M.gguf")!,
            sha256: "8270790f3ab69fdfe860b7b64008d9a19986d8df7e407bb018184caa08798ebd",
            jobs: [.reading],
            blurb: "Small Read Aloud fallback. Do not use for enhancement."
        ),
        LocalLLMPackage(
            fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
            displayName: "Gemma 4 E4B",
            approxSize: "~5.0 GB",
            estimatedRAMGB: 6.0,
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/gemma-4-E4B-it-Q4_K_M.gguf")!,
            sha256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87",
            jobs: [.reading],
            blurb: "Larger Read Aloud model. Explicit opt-in."
        ),
        LocalLLMPackage(
            fileName: "gemma-4-12b-it-Q4_K_M.gguf",
            displayName: "Gemma 4 12B",
            approxSize: "~7.1 GB",
            estimatedRAMGB: 9.0,
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/gemma-4-12b-it-Q4_K_M.gguf")!,
            sha256: "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42",
            jobs: [.reading],
            blurb: "Heavy Read Aloud model. Explicit opt-in."
        ),
        LocalLLMPackage(
            fileName: "gemma-3-27b-it-Q4_K_M.gguf",
            displayName: "Gemma 3 27B",
            approxSize: "~16.5 GB",
            estimatedRAMGB: 19.0,
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-3-27b-it-GGUF/resolve/7cd0121f2530b00e42c4df952d4cad4418c0b3c1/gemma-3-27b-it-Q4_K_M.gguf")!,
            sha256: "f1b699659942c777bd3ec0bcb527d6ebf34ae14ca76e3af103d58d0c9cbdadee",
            jobs: [.reading],
            blurb: "Largest Read Aloud model. Explicit opt-in."
        )
    ]

    nonisolated static func packages(for role: LocalLLMRole) -> [LocalLLMPackage] {
        packages.filter { $0.jobs.contains(role) }
    }

    /// The shipped default for Read Aloud and any caller that still asks for "the" model.
    nonisolated static let defaultPackage = packages.first {
        $0.fileName == "gemma-4-E2B_q4_0-it.gguf"
    } ?? packages[0]

    /// Instant + Refine default.
    ///
    /// Chosen on measurement, not on size. Against the shipped system prompt over a 20-case
    /// dictation set, Gemma 4 E2B was the only model that kept mixed Hebrew/English in its
    /// original script (2/2 on every run); every smaller candidate translated it (0/2 on every
    /// run), which `EnhancementLanguageGuard` then rejects — leaving those lines unenhanced.
    /// The self-introduction that kept Gemma off this job in 2.8.3 is handled by the hardened
    /// prompt and by `EnhancementLanguageGuard.looksLikeSelfIntroduction`.
    nonisolated static let enhancementDefaultPackage = packages.first {
        $0.fileName == "gemma-4-E2B_q4_0-it.gguf"
    } ?? packages[0]

    /// Best quality/performance balance for this Mac. Displayed as guidance; it never silently
    /// replaces an installed or explicitly selected model.
    nonisolated static var recommendedPackage: LocalLLMPackage {
        packages.first { $0.fileName == HardwareCapability.recommendedLocalLLMFileName }
            ?? defaultPackage
    }

    nonisolated private static let currentModelKey = "CurrentLocalLLMModel"
    nonisolated static let enhancementModelKey = "EnhancementLocalLLMModel"

    /// The currently-selected on-device model (shared by Enhancement + Read Aloud).
    nonisolated static var current: LocalLLMPackage {
        let saved = UserDefaults.standard.string(forKey: currentModelKey)
        if let selected = packages.first(where: { $0.fileName == saved }) {
            return selected
        }

        // Preserve installations that predate explicit model selection, but never infer that the
        // largest model found on disk is the desired one. Prefer the default, then the smallest
        // installed catalogue entry.
        let modelDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("com.arcusis.zerm")
            .appendingPathComponent("LLMModels")
        let compatibilityOrder = [defaultPackage.fileName] + packages.map(\.fileName)
        if let installedFile = compatibilityOrder.first(where: {
            FileManager.default.fileExists(
                atPath: modelDirectory.appendingPathComponent($0).path
            )
        }), let installed = packages.first(where: { $0.fileName == installedFile }) {
            return installed
        }
        return recommendedPackage
    }

    /// Package for a job. Enhancement prefers the tiny default once it is on disk,
    /// otherwise the already-installed reading model so Instant + Refine does not
    /// go dark for people who only have Gemma.
    nonisolated static func package(for role: LocalLLMRole) -> LocalLLMPackage {
        switch role {
        case .reading:
            return current
        case .enhancement:
            let saved = UserDefaults.standard.string(forKey: enhancementModelKey)
            if let selected = packages.first(where: { $0.fileName == saved }),
               isDownloadedOnDisk(selected) {
                return selected
            }
            if isDownloadedOnDisk(enhancementDefaultPackage) {
                return enhancementDefaultPackage
            }
            if isDownloadedOnDisk(current) {
                return current
            }
            return enhancementDefaultPackage
        }
    }

    nonisolated private static func isDownloadedOnDisk(_ package: LocalLLMPackage) -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
        let path = appSupport.appendingPathComponent("LLMModels").appendingPathComponent(package.fileName).path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Backward-compatible alias for the many call sites that referenced the single package;
    /// it now resolves to the currently-selected model.
    nonisolated static var package: LocalLLMPackage { current }

    @Published private(set) var installedFiles: Set<String> = []
    /// Per-model download progress (0.0–1.0), keyed by fileName; absent when not downloading.
    @Published private(set) var downloadProgress: [String: Double] = [:]
    /// Mirrors the persisted current-model selection so SwiftUI updates on change.
    @Published private(set) var currentFileName: String = LocalLLMModelManager.current.fileName
    @Published private(set) var enhancementFileName: String = LocalLLMModelManager.package(for: .enhancement).fileName
    @Published private(set) var statusText: String?

    let modelsDirectory: URL
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "LocalLLMModelManager")
    private var engines: [String: LlamaEngine] = [:]
    private var activeOperations = 0
    private var idleUnloadTask: Task<Void, Never>?
    private static let idleUnloadDelayNanoseconds: UInt64 = 120_000_000_000
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

    /// Thread-safe install check for the current reading model, usable from non-main contexts (e.g. `AIService`).
    nonisolated static var isModelDownloaded: Bool {
        isDownloadedOnDisk(current)
    }

    nonisolated static func isModelDownloaded(for role: LocalLLMRole) -> Bool {
        isDownloadedOnDisk(package(for: role))
    }

    // MARK: - Selection

    /// Switch the active on-device model. Unloads the previous engine so the next generation
    /// loads the newly-selected weights.
    func select(_ package: LocalLLMPackage) {
        select(package, role: .reading)
    }

    func select(_ package: LocalLLMPackage, role: LocalLLMRole) {
        switch role {
        case .reading:
            guard package.fileName != currentFileName else { return }
            UserDefaults.standard.set(package.fileName, forKey: Self.currentModelKey)
            currentFileName = package.fileName
        case .enhancement:
            guard package.fileName != enhancementFileName else { return }
            UserDefaults.standard.set(package.fileName, forKey: Self.enhancementModelKey)
            enhancementFileName = package.fileName
        }
        cancelIdleUnload()
    }

    // MARK: - Download

    func download(_ package: LocalLLMPackage) async {
        guard !package.hardwareFit.blocksInstall else {
            statusText = "\(package.displayName) needs more memory than this Mac has available"
            return
        }
        guard downloadProgress[package.fileName] == nil else { return }
        downloadProgress[package.fileName] = 0
        statusText = nil
        defer { downloadProgress[package.fileName] = nil }

        do {
            let file = try await downloadFile(for: package)
            // Reject a tampered/corrupt GGUF before llama.cpp ever parses it.
            guard ModelIntegrity.verify(fileURL: file, expectedSHA256: package.sha256) else {
                try? FileManager.default.removeItem(at: file)
                logger.error("Checksum mismatch for \(package.fileName, privacy: .public); download rejected")
                statusText = "Download failed integrity check and was discarded"
                return
            }
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
        if engines[package.fileName] != nil {
            cancelIdleUnload()
            engines[package.fileName] = nil
        }
        try? FileManager.default.removeItem(at: path(for: package))
        refreshInstalled()
        enhancementFileName = Self.package(for: .enhancement).fileName
        currentFileName = Self.current.fileName
    }

    /// Deletes the current model (backward-compatible no-arg form).
    func delete() { delete(currentPackage) }

    /// Release the warm engines so they don't pin RAM after idle.
    func unloadIfIdle() {
        guard activeOperations == 0, !engines.isEmpty else { return }
        cancelIdleUnload()
        logger.notice("Unloading local LLM engines (idle / memory reclaim)")
        engines.removeAll()
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

    /// Rewrites/answers using the model for `role`. Loads it on first use.
    func generate(
        system: String,
        user: String,
        maxNewTokens: Int = 400,
        role: LocalLLMRole = .reading,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> String {
        let package = Self.package(for: role)
        guard isDownloaded(package) else {
            throw TTSError.notAvailable("The on-device model isn't downloaded yet. Download it in Enhancement or Read Aloud settings.")
        }
        beginOperation()
        defer { endOperation() }
        let engine = ensureEngine(for: package, role: role)
        // Thinking is suppressed in the prompt template by `LlamaBridge`, not by appending the
        // `/no_think` soft switch to the user turn. The soft switch still let Qwen3 open a
        // `<think>` block, and it put a stray token inside the text the model was asked to clean.
        return try await engine.generate(system: system, user: user, maxNewTokens: maxNewTokens, isCancelled: isCancelled)
    }

    /// Pre-loads the current model in the background so the first natural read is fast.
    func prewarmIfNeeded() async {
        guard TTSSettings.naturalReadingAI else { return }
        await prewarm(role: .reading)
    }

    /// Pre-loads the Instant + Refine model so it is resident before transcription finishes.
    func prewarm() async {
        await prewarm(role: .enhancement)
    }

    func prewarm(role: LocalLLMRole) async {
        let package = Self.package(for: role)
        guard isDownloaded(package) else { return }
        beginOperation()
        defer { endOperation() }
        let engine = ensureEngine(for: package, role: role)
        try? await engine.warmUp()
    }

    private func ensureEngine(for package: LocalLLMPackage, role: LocalLLMRole) -> LlamaEngine {
        cancelIdleUnload()
        if let engine = engines[package.fileName] { return engine }
        let contextSize = role == .enhancement
            ? min(2_048, HardwareCapability.localLLMContextSize)
            : HardwareCapability.localLLMContextSize
        let engine = LlamaEngine(
            modelPath: path(for: package).path,
            contextSize: contextSize,
            threadCount: HardwareCapability.inferenceThreadCount,
            disablesThinking: package.disablesThinking
        )
        engines[package.fileName] = engine
        return engine
    }

    private func beginOperation() {
        cancelIdleUnload()
        activeOperations += 1
    }

    private func endOperation() {
        activeOperations = max(0, activeOperations - 1)
        guard activeOperations == 0, !engines.isEmpty else { return }
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.idleUnloadDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.unloadIfIdle()
        }
    }

    private func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }
}
