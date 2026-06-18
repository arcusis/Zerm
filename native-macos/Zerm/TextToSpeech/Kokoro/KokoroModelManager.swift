import Foundation
import os

/// Describes the downloadable sherpa-onnx Kokoro model package.
struct KokoroModelPackage {
    let name: String          // archive base name, also the extracted folder name
    let displayName: String
    let approxSize: String
    let downloadURL: URL

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
        displayName: "Kokoro 82M (English, on-device)",
        approxSize: "~330 MB",
        downloadURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2")!
    )

    @Published private(set) var isInstalled = false
    @Published private(set) var isDownloading = false
    /// 0.0–1.0 while downloading/extracting; nil when idle.
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var statusText: String?

    let modelsDirectory: URL
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "KokoroModelManager")
    private var engine: KokoroEngine?
    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
        modelsDirectory = appSupport.appendingPathComponent("TTSModels")
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        refreshInstalled()
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
            dataDir: packageDir.appendingPathComponent(Self.package.dataDirName).path
        )
    }

    func refreshInstalled() {
        let fm = FileManager.default
        let filesPresent = Self.package.requiredFiles.allSatisfy {
            fm.fileExists(atPath: packageDir.appendingPathComponent($0).path)
        }
        let dataPresent = fm.fileExists(atPath: packageDir.appendingPathComponent(Self.package.dataDirName).path)
        isInstalled = filesPresent && dataPresent
    }

    // MARK: - Download + extract

    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        statusText = "Downloading Kokoro model…"
        defer { isDownloading = false; downloadProgress = nil }

        do {
            let archiveURL = try await downloadArchive(from: Self.package.downloadURL)
            statusText = "Extracting…"
            downloadProgress = nil
            try extractTarBz2(at: archiveURL, into: modelsDirectory)
            try? FileManager.default.removeItem(at: archiveURL)
            refreshInstalled()
            statusText = isInstalled ? nil : "Extraction incomplete"
            if !isInstalled { logger.error("Kokoro extraction finished but required files are missing") }
        } catch is CancellationError {
            statusText = "Download cancelled"
        } catch {
            logger.error("Kokoro download failed: \(error.localizedDescription, privacy: .public)")
            statusText = "Download failed: \(error.localizedDescription)"
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    func delete() {
        engine = nil
        try? FileManager.default.removeItem(at: packageDir)
        refreshInstalled()
    }

    /// Downloads to a temp file, reporting fractional progress via KVO (mirrors WhisperModelManager).
    private func downloadArchive(from url: URL) async throws -> URL {
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
                    let dest = self?.modelsDirectory.appendingPathComponent("kokoro-download.tar.bz2")
                        ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kokoro.tar.bz2")
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
            throw TTSError.notAvailable("Failed to extract model: \(String(data: errData, encoding: .utf8) ?? "tar error")")
        }
    }

    // MARK: - Synthesis

    /// Synthesizes `text` with the given speaker id (sid) and speed, returning 16-bit PCM.
    /// Loads the engine on first use; runs inference off the main thread.
    func synthesize(text: String, sid: Int, speed: Double) async throws -> TTSAudio {
        guard isInstalled else {
            throw TTSError.notAvailable("The on-device Kokoro model isn't downloaded yet. Download it in Read Aloud settings.")
        }
        let engine = ensureEngine()
        let (samples, sampleRate) = try await engine.generate(text: text, sid: sid, speed: Float(speed))
        guard !samples.isEmpty else { throw TTSError.emptyAudio }
        return TTSAudio(pcm: Self.floatToInt16PCM(samples), sampleRate: Double(sampleRate), channels: 1)
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

    /// Converts sherpa-onnx Float samples ([-1, 1]) to signed 16-bit little-endian PCM.
    private static func floatToInt16PCM(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            var v = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        return data
    }
}
