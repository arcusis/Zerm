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
        case .enhancement: return String(localized: "Enhancement")
        case .reading: return String(localized: "Read Aloud")
        }
    }

    var jobDescription: String {
        switch self {
        case .enhancement:
            return String(localized: "Cleans the transcript after dictation. Must stay instant. Do not use a chatbot.")
        case .reading:
            return String(localized: "Retells selected text before it is spoken. Can be a larger model.")
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
            blurb: String(localized: "Default for both jobs. The only catalogue model that leaves mixed-language dictation in its original script.")
        ),
        LocalLLMPackage(
            fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            displayName: "Qwen3 4B Instruct",
            approxSize: "~2.5 GB",
            estimatedRAMGB: 3.2,
            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
            sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
            jobs: [.enhancement],
            blurb: String(localized: "Smaller opt-in. Matches the default on English cleanup, but translates mixed-language dictation instead of preserving it.")
        ),
        LocalLLMPackage(
            fileName: "gemma-3-1b-it-Q4_K_M.gguf",
            displayName: "Gemma 3 1B",
            approxSize: "~806 MB",
            estimatedRAMGB: 1.5,
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/f0b45be0aac41bd6a100a4b5734cad5f67255bfb/gemma-3-1b-it-Q4_K_M.gguf")!,
            sha256: "8270790f3ab69fdfe860b7b64008d9a19986d8df7e407bb018184caa08798ebd",
            jobs: [.reading],
            blurb: String(localized: "Small Read Aloud fallback. Do not use for enhancement.")
        ),
        LocalLLMPackage(
            fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
            displayName: "Gemma 4 E4B",
            approxSize: "~5.0 GB",
            estimatedRAMGB: 6.0,
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/gemma-4-E4B-it-Q4_K_M.gguf")!,
            sha256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87",
            jobs: [.reading],
            blurb: String(localized: "Larger Read Aloud model. Explicit opt-in.")
        ),
        LocalLLMPackage(
            fileName: "gemma-4-12b-it-Q4_K_M.gguf",
            displayName: "Gemma 4 12B",
            approxSize: "~7.1 GB",
            estimatedRAMGB: 9.0,
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/fc034cfff751157913579611efad8462ac1be606/gemma-4-12b-it-Q4_K_M.gguf")!,
            sha256: "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42",
            jobs: [.reading],
            blurb: String(localized: "Heavy Read Aloud model. Explicit opt-in.")
        ),
        LocalLLMPackage(
            fileName: "gemma-3-27b-it-Q4_K_M.gguf",
            displayName: "Gemma 3 27B",
            approxSize: "~16.5 GB",
            estimatedRAMGB: 19.0,
            downloadURL: URL(string: "https://huggingface.co/unsloth/gemma-3-27b-it-GGUF/resolve/7cd0121f2530b00e42c4df952d4cad4418c0b3c1/gemma-3-27b-it-Q4_K_M.gguf")!,
            sha256: "f1b699659942c777bd3ec0bcb527d6ebf34ae14ca76e3af103d58d0c9cbdadee",
            jobs: [.reading],
            blurb: String(localized: "Largest Read Aloud model. Explicit opt-in.")
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
        let modelDirectory = AppStoragePaths.root
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

    /// Package for a job.
    nonisolated static func package(for role: LocalLLMRole) -> LocalLLMPackage {
        switch role {
        case .reading:
            return current
        case .enhancement:
            return enhancementPackage(
                saved: UserDefaults.standard.string(forKey: enhancementModelKey),
                reading: current,
                isDownloaded: isDownloadedOnDisk
            )
        }
    }

    /// The enhancement model to use: the user's pick while it is on disk, else the default, else
    /// the installed Read Aloud model when it can also enhance (Gemma 4 E2B is both jobs' default,
    /// and is the only model many installs have), else any installed enhancement model. A model
    /// that is only fit for Read Aloud is never borrowed. With nothing installed, the pick or the
    /// default is returned so settings can offer its download.
    nonisolated static func enhancementPackage(
        saved: String?,
        reading: LocalLLMPackage,
        isDownloaded: (LocalLLMPackage) -> Bool
    ) -> LocalLLMPackage {
        let enhancementPackages = packages(for: .enhancement)
        let selected = enhancementPackages.first { $0.fileName == saved }
        if let selected, isDownloaded(selected) { return selected }
        if isDownloaded(enhancementDefaultPackage) { return enhancementDefaultPackage }
        if reading.jobs.contains(.enhancement), isDownloaded(reading) { return reading }
        return enhancementPackages.first(where: isDownloaded) ?? selected ?? enhancementDefaultPackage
    }

    /// An enhancement package by the display or file name a prompt or Power Mode stores. Any other
    /// name — a Read Aloud model 2.8.5 saved there — resolves to the enhancement model in use.
    nonisolated static func enhancementPackage(named name: String) -> LocalLLMPackage {
        packages(for: .enhancement).first { $0.displayName == name || $0.fileName == name }
            ?? package(for: .enhancement)
    }

    nonisolated static func isDownloaded(_ package: LocalLLMPackage) -> Bool {
        isDownloadedOnDisk(package)
    }

    nonisolated private static func isDownloadedOnDisk(_ package: LocalLLMPackage) -> Bool {
        let appSupport = AppStoragePaths.root
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
        let appSupport = AppStoragePaths.root
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
        // Which enhancement model is in use depends on what is on disk.
        enhancementFileName = Self.package(for: .enhancement).fileName
    }

    func isDownloaded(_ package: LocalLLMPackage) -> Bool { installedFiles.contains(package.fileName) }
    func isDownloading(_ package: LocalLLMPackage) -> Bool { downloadProgress[package.fileName] != nil }

    /// True when the *current* model is downloaded (backward-compatible single-model check).
    var isInstalled: Bool { isDownloaded(currentPackage) }

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
            statusText = String(localized: "\(package.displayName) needs more memory than this Mac has available")
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
                statusText = String(localized: "Download failed integrity check and was discarded")
                return
            }
            let dest = path(for: package)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: file, to: dest)
            refreshInstalled()
        } catch is CancellationError {
            statusText = String(localized: "Download cancelled")
        } catch {
            logger.error("LLM download failed: \(error.localizedDescription, privacy: .public)")
            statusText = String(localized: "Download failed: \(error.localizedDescription)")
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
                    continuation.resume(throwing: TTSError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(localized: "download failed")))
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

    /// Rewrites/answers using the model for `role`, or exactly `packageFileName` when a request has
    /// already resolved one. Loads it on first use.
    func generate(
        system: String,
        user: String,
        maxNewTokens: Int = 400,
        role: LocalLLMRole = .reading,
        packageFileName: String? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> String {
        let package = Self.packages.first { $0.fileName == packageFileName } ?? Self.package(for: role)
        guard isDownloaded(package) else {
            throw TTSError.notAvailable(String(localized: "The on-device model isn't downloaded yet. Download it in Enhancement or Read Aloud settings."))
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
        let contextSize = role == .enhancement
            ? min(2_048, HardwareCapability.localLLMContextSize)
            : HardwareCapability.localLLMContextSize
        // Enhancement and Read Aloud can share one weights file. An engine built for the
        // enhancement's 2K window silently truncates Read Aloud's instructions on longer
        // selections, so a smaller cached engine is replaced rather than reused.
        if let engine = engines[package.fileName], engine.contextSize >= contextSize { return engine }
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
