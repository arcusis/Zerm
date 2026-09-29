import Foundation
import os

/// Describes the downloadable sherpa-onnx Kokoro model package.
struct KokoroModelPackage {
    let name: String          // archive base name, also the extracted folder name
    let displayName: String
    let approxSize: String
    let downloadURL: URL
    var provenance: ModelProvenance {
        ModelProvenance(
            creator: "hexgrad / sherpa-onnx",
            sourceURL: downloadURL,
            downloadHost: "github.com",
            licenseName: "Apache-2.0",
            licenseSPDX: "Apache-2.0",
            licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
            attribution: "Kokoro model package distributed by sherpa-onnx.",
            conversionCredit: "sherpa-onnx",
            checksumSHA256: nil
        )
    }

    /// Files that must exist after extraction for the package to be considered installed.
    var requiredFiles: [String] { ["model.onnx", "voices.bin", "tokens.txt"] }
    /// espeak-ng phonemizer data directory (required by Kokoro).
    var dataDirName: String { "espeak-ng-data" }
}

/// Downloads, stores, and serves the on-device Kokoro TTS model — the synthesis
/// counterpart of `WhisperModelManager`. Same UX: first use auto-downloads with a
/// progress bar, then everything runs offline.
@MainActor
final class KokoroModelManager: ObservableObject {
    static let shared = KokoroModelManager()

    /// English Kokoro v0.19 (11 speakers) — Apache-2.0 weights, hosted on the sherpa-onnx release.
    static let package = KokoroModelPackage(
        name: "kokoro-en-v0_19",
        displayName: String(localized: "Kokoro 82M (English, on-device)"),
        approxSize: "~330 MB",
        downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2")!
    )

    @Published private(set) var isInstalled = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isPaused = false
    /// 0.0–1.0 while downloading/extracting; nil when idle.
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadedBytes: Int64?
    @Published private(set) var totalDownloadBytes: Int64?
    @Published private(set) var downloadState: ModelDownloadState?
    @Published private(set) var statusText: String?

    let modelsDirectory: URL
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "KokoroModelManager")
    private var engine: KokoroEngine?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    private let resumeDataStore = ModelDownloadResumeDataStore()
    private let downloadStateStore = ModelDownloadStateStore()
    private var pauseRequested = false

    private init() {
        let appSupport = AppStoragePaths.root
        modelsDirectory = appSupport.appendingPathComponent("TTSModels")
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        refreshInstalled()
        downloadState = downloadStateStore.load(for: Self.package.name)
        downloadedBytes = downloadState?.bytesDownloaded
        totalDownloadBytes = downloadState?.totalBytes
        if resumeDataStore.load(for: Self.package.name) != nil {
            isPaused = true
            statusText = String(localized: "Paused")
        }
    }

    // MARK: - Paths

    private var packageDir: URL {
        modelsDirectory.appendingPathComponent(Self.package.name)
    }

    /// Resolved config paths sherpa-onnx needs.
    var modelConfig: (model: String, voices: String, tokens: String, dataDir: String) {
        (
            model: packageDir.appendingPathComponent("model.onnx").path,
            voices: packageDir.appendingPathComponent("voices.bin").path,
            tokens: packageDir.appendingPathComponent("tokens.txt").path,
            dataDir: EspeakDataSupport.dataDirectory(in: modelsDirectory).path
        )
    }

    func refreshInstalled() {
        let fm = FileManager.default
        let filesPresent = Self.package.requiredFiles.allSatisfy {
            fm.fileExists(atPath: packageDir.appendingPathComponent($0).path)
        }
        let dataPresent = EspeakDataSupport.containsData(in: modelsDirectory)
        isInstalled = filesPresent && dataPresent
    }

    // MARK: - Download + extract

    func download() async {
        guard !isDownloading else { return }
        isPaused = false
        pauseRequested = false
        isDownloading = true
        downloadState = ModelDownloadState(phase: resumeDataStore.load(for: Self.package.name) == nil ? .downloading : .resuming)
        try? downloadStateStore.save(downloadState!, for: Self.package.name)
        downloadProgress = 0
        statusText = String(localized: "Downloading Kokoro model…")
        defer { isDownloading = false; downloadProgress = nil }

        do {
            let archiveURL = try await downloadArchive(from: Self.package.downloadURL)
            statusText = String(localized: "Extracting…")
            downloadProgress = nil
            try extractTarBz2(at: archiveURL, into: modelsDirectory)
            try? FileManager.default.removeItem(at: archiveURL)
            refreshInstalled()
            statusText = isInstalled ? nil : String(localized: "Extraction incomplete")
            if !isInstalled { logger.error("Kokoro extraction finished but required files are missing") }
            if isInstalled {
                downloadState = ModelDownloadState(phase: .completed, fractionCompleted: 1)
                try? downloadStateStore.save(downloadState!, for: Self.package.name)
            }
        } catch is CancellationError {
            isPaused = pauseRequested
            statusText = isPaused ? String(localized: "Paused") : String(localized: "Download cancelled")
            downloadState = ModelDownloadState(phase: isPaused ? .paused : .queued, fractionCompleted: downloadState?.fractionCompleted, bytesDownloaded: downloadedBytes, totalBytes: totalDownloadBytes)
            try? downloadStateStore.save(downloadState!, for: Self.package.name)
        } catch {
            if pauseRequested {
                isPaused = true
                statusText = String(localized: "Paused")
                downloadState = ModelDownloadState(phase: .paused, fractionCompleted: downloadState?.fractionCompleted, bytesDownloaded: downloadedBytes, totalBytes: totalDownloadBytes)
                try? downloadStateStore.save(downloadState!, for: Self.package.name)
                return
            }
            logger.error("Kokoro download failed: \(error.localizedDescription, privacy: .public)")
            let format = String(localized: "Download failed: %@")
            statusText = String.localizedStringWithFormat(format, error.localizedDescription)
            downloadState = ModelDownloadState(phase: .failed, fractionCompleted: downloadProgress, bytesDownloaded: downloadedBytes, totalBytes: totalDownloadBytes, message: error.localizedDescription)
            try? downloadStateStore.save(downloadState!, for: Self.package.name)
        }
    }

    func cancelDownload() {
        isPaused = false
        resumeDataStore.remove(for: Self.package.name)
        downloadState = ModelDownloadState(phase: .queued)
        try? downloadStateStore.save(downloadState!, for: Self.package.name)
        downloadTask?.cancel()
        downloadTask = nil
        statusText = String(localized: "Download cancelled")
    }

    func pauseDownload() {
        guard let downloadTask else { return }
        pauseRequested = true
        let packageName = Self.package.name
        downloadTask.cancel(byProducingResumeData: { [resumeDataStore] data in
            if let data { try? resumeDataStore.save(data, for: packageName) }
        })
        statusText = String(localized: "Pausing…")
    }

    func resumeDownload() {
        Task { @MainActor in
            while isDownloading { try? await Task.sleep(for: .milliseconds(20)) }
            await download()
        }
    }

    func delete() {
        engine = nil
        try? FileManager.default.removeItem(at: packageDir)
        refreshInstalled()
    }

    /// Downloads to a temp file, reporting fractional progress via KVO (mirrors WhisperModelManager).
    private func downloadArchive(from url: URL) async throws -> URL {
        let archiveDestination = modelsDirectory.appendingPathComponent("kokoro-download.tar.bz2")
        let resumeStore = resumeDataStore
        let packageName = Self.package.name
        defer {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { [weak self] tempURL, response, error in
                Task { @MainActor in self?.downloadTask = nil }
                if let error { continuation.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continuation.resume(throwing: TTSError.http((response as? HTTPURLResponse)?.statusCode ?? -1, String(localized: "download failed")))
                    return
                }
                guard let tempURL else { continuation.resume(throwing: TTSError.badResponse); return }
                do {
                    try? FileManager.default.removeItem(at: archiveDestination)
                    try FileManager.default.moveItem(at: tempURL, to: archiveDestination)
                    resumeStore.remove(for: packageName)
                    continuation.resume(returning: archiveDestination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let resumeData = resumeStore.load(for: packageName)
            let task = resumeData.map { URLSession.shared.downloadTask(withResumeData: $0, completionHandler: completion) }
                ?? URLSession.shared.downloadTask(with: url, completionHandler: completion)
            self.downloadTask = task
            self.progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                Task { @MainActor in
                    self?.downloadProgress = progress.fractionCompleted
                    self?.downloadedBytes = progress.completedUnitCount
                    self?.totalDownloadBytes = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
                    guard let self else { return }
                    var state = self.downloadState ?? ModelDownloadState(phase: .downloading)
                    state.fractionCompleted = progress.fractionCompleted
                    state.bytesDownloaded = progress.completedUnitCount
                    state.totalBytes = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
                    self.downloadState = state
                    try? self.downloadStateStore.save(state, for: Self.package.name)
                }
            }
            task.resume()
        }
    }

    /// Extracts a .tar.bz2 via bsdtar (`/usr/bin/tar`), which handles bzip2 natively on macOS.
    private func extractTarBz2(at archiveURL: URL, into dest: URL) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-x", "-j", "-f", archiveURL.path, "-C", dest.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()  // drain before wait
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let format = String(localized: "Failed to extract model: %@")
            let detail = String(data: errData, encoding: .utf8)
                ?? String(localized: "Archive extraction error")
            throw TTSError.notAvailable(String.localizedStringWithFormat(format, detail))
        }
    }

    // MARK: - Synthesis

    /// Synthesizes `text` with the given speaker id (sid) and speed, returning 16-bit PCM.
    /// Loads the engine on first use; runs inference off the main thread.
    func synthesize(text: String, sid: Int, speed: Double) async throws -> TTSAudio {
        guard isInstalled else {
            throw TTSError.notAvailable(String(localized: "The on-device Kokoro model isn't downloaded yet. Download it in Read Aloud settings."))
        }
        let engine = ensureEngine()
        return try await engine.generateAudio(text: text, sid: sid, speed: Float(speed))
    }

    /// Pre-loads the model in the background when Kokoro is the selected provider, so the
    /// first read-aloud is instant instead of a cold ~330 MB load.
    func prewarmIfNeeded() async {
        guard isInstalled, TTSSettings.providerKind == .kokoro else { return }
        let engine = ensureEngine()
        try? await engine.warmUp()
    }

    private func ensureEngine() -> KokoroEngine {
        if let engine { return engine }
        let cfg = modelConfig
        let engine = KokoroEngine(model: cfg.model, voices: cfg.voices, tokens: cfg.tokens, dataDir: cfg.dataDir)
        self.engine = engine
        return engine
    }

}
