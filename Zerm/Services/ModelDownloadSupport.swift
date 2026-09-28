import Foundation

final class ModelDownloadRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var isCancelled = false

    func install(task: URLSessionDownloadTask, observation: NSKeyValueObservation) -> Bool {
        lock.withLock {
            guard !isCancelled else { return false }
            self.task = task
            self.observation = observation
            return true
        }
    }

    func finish() {
        let observation = lock.withLock { () -> NSKeyValueObservation? in
            defer {
                self.observation = nil
                task = nil
            }
            return self.observation
        }
        observation?.invalidate()
    }

    func cancel() {
        let (task, observation) = lock.withLock { () -> (URLSessionDownloadTask?, NSKeyValueObservation?) in
            isCancelled = true
            defer {
                self.task = nil
                self.observation = nil
            }
            return (self.task, self.observation)
        }
        observation?.invalidate()
        task?.cancel()
    }

    func pause(resumeDataStore: ModelDownloadResumeDataStore, assetID: String) {
        let task = lock.withLock { self.task }
        task?.cancel(byProducingResumeData: { data in
            if let data { try? resumeDataStore.save(data, for: assetID) }
        })
    }
}

enum ModelDownloadPhase: String, Codable, Equatable, Sendable {
    case queued
    case downloading
    case paused
    case resuming
    case failed
    case completed
}

struct ModelDownloadState: Codable, Equatable, Sendable {
    var phase: ModelDownloadPhase
    var fractionCompleted: Double? = nil
    var bytesDownloaded: Int64? = nil
    var totalBytes: Int64? = nil
    var message: String? = nil

    mutating func transition(to phase: ModelDownloadPhase) {
        self.phase = phase
    }
}

struct ModelDownloadStateMachine: Equatable, Sendable {
    private(set) var state: ModelDownloadState

    init(state: ModelDownloadState = .init(phase: .queued)) {
        self.state = state
    }

    mutating func start(resuming: Bool = false) {
        state.transition(to: resuming ? .resuming : .downloading)
        state.message = nil
    }

    mutating func update(bytesDownloaded: Int64, totalBytes: Int64?) {
        state.bytesDownloaded = bytesDownloaded
        state.totalBytes = totalBytes
        state.fractionCompleted = totalBytes.flatMap { $0 > 0 ? min(1, Double(bytesDownloaded) / Double($0)) : nil }
    }

    mutating func pause() { state.transition(to: .paused) }
    mutating func cancel() { state = ModelDownloadState(phase: .queued) }
    mutating func fail(_ message: String) { state.phase = .failed; state.message = message }
    mutating func complete() { state.phase = .completed; state.fractionCompleted = 1; state.message = nil }
}

struct ModelDownloadStateStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "model-download-state") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func save(_ state: ModelDownloadState, for assetID: String) throws {
        defaults.set(try JSONEncoder().encode(state), forKey: keyPrefix + "." + assetID)
    }

    func load(for assetID: String) -> ModelDownloadState? {
        guard let data = defaults.data(forKey: keyPrefix + "." + assetID) else { return nil }
        return try? JSONDecoder().decode(ModelDownloadState.self, from: data)
    }

    func remove(for assetID: String) { defaults.removeObject(forKey: keyPrefix + "." + assetID) }
}

struct ModelDownloadResumeDataStore: Sendable {
    let directory: URL

    init(directory: URL = AppStoragePaths.root.appendingPathComponent("DownloadResumeData", isDirectory: true)) {
        self.directory = directory
    }

    func save(_ data: Data, for assetID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: assetID), options: .atomic)
    }

    func load(for assetID: String) -> Data? { try? Data(contentsOf: fileURL(for: assetID)) }

    func remove(for assetID: String) { try? FileManager.default.removeItem(at: fileURL(for: assetID)) }

    private func fileURL(for assetID: String) -> URL {
        let safeID = Data(assetID.utf8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(safeID + ".resume")
    }
}

struct ModelDownloadAcceptanceStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "model-download-acceptance") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func hasAccepted(assetID: String, licenseVersion: String) -> Bool {
        defaults.bool(forKey: key(assetID: assetID, licenseVersion: licenseVersion))
    }

    func accept(assetID: String, licenseVersion: String) {
        defaults.set(true, forKey: key(assetID: assetID, licenseVersion: licenseVersion))
    }

    private func key(assetID: String, licenseVersion: String) -> String {
        keyPrefix + "." + assetID + "." + licenseVersion
    }
}

enum ModelDownloadPolicy {
    static func requiresExplicitAgreement(assetID: String) -> Bool { assetID == "gemma-3-1b-it-Q4_K_M.gguf" || assetID == "gemma-3-27b-it-Q4_K_M.gguf" }

    static func licenseVersion(for provenance: ModelProvenance) -> String {
        provenance.licenseSPDX ?? provenance.licenseName
    }
}
