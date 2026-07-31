import AVFoundation
import Combine
import CoreAudio
import Foundation
import OSLog

/// One meeting, from the moment recording starts until the files are closed.
///
/// The microphone and the system output are captured as **separate tracks**. Mixing them at
/// capture time would be cheaper, but two tracks mean the local speaker and the remote
/// participants are already separated on disk — attribution without diarisation — and either
/// side can be re-transcribed on its own later.
///
/// Unlike dictation, this is expected to run for hours, so both tracks stream to disk as they
/// arrive and nothing accumulates in memory.
@MainActor
final class MeetingRecordingSession: ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case stopping
        case failed(String)
    }

    struct Sources: OptionSet {
        let rawValue: Int
        static let microphone = Sources(rawValue: 1 << 0)
        static let systemAudio = Sources(rawValue: 1 << 1)
        static let all: Sources = [.microphone, .systemAudio]
    }

    /// What a finished recording left on disk.
    struct Recording: Equatable {
        let id: UUID
        let folder: URL
        let startedAt: Date
        let duration: TimeInterval
        let microphoneTrack: URL?
        let systemAudioTrack: URL?
    }

    enum SessionError: LocalizedError {
        case alreadyRecording
        case noSourcesSelected
        case noMicrophoneDevice
        case systemAudioUnavailable
        case notEnoughDiskSpace(availableMB: Int)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already running."
            case .noSourcesSelected:
                return "Choose at least one thing to record."
            case .noMicrophoneDevice:
                return "No microphone is available to record from."
            case .systemAudioUnavailable:
                return "Recording system audio needs macOS 14.2 or later."
            case .notEnoughDiskSpace(let availableMB):
                return "Only \(availableMB) MB of disk space is free. Free up some space before recording a meeting."
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var microphoneLevelDb: Float = -160
    @Published private(set) var systemAudioLevelDb: Float = -160

    /// System audio is being captured but nothing has ever come through.
    ///
    /// Almost always the missing `kTCCServiceAudioCapture` permission: an unauthorised process
    /// tap reports success on every call and delivers pure silence, so this is the only signal
    /// there is. It can also simply mean nothing is playing yet, which is why it reads as a
    /// hint for the UI rather than an error.
    @Published private(set) var systemAudioSilent = false

    /// 16 kHz mono Int16 chunks from whichever sources are live, for on-the-fly transcription.
    /// Both tracks feed this, so a live transcript covers the whole conversation.
    var onTranscriptionChunk: ((Data) -> Void)?

    /// The microphone alone — the room you are sitting in. Kept separate from the merged feed
    /// because diarisation only makes sense per side: the system track is already known to be
    /// the remote participants, so only the local room needs voices told apart.
    var onMicrophoneChunk: ((Data) -> Void)?

    /// The system output alone — everyone joining through the call.
    var onSystemAudioChunk: ((Data) -> Void)?

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingRecordingSession")

    private let microphone = CoreAudioRecorder()
    private var systemTapStorage: AnyObject?
    private let systemWriter = SystemAudioTrackWriter()

    private var activeSources: Sources = []
    private var recordingID: UUID?
    /// Where the live recording is being written, so the transcript can be journalled beside it.
    private(set) var folder: URL?
    private var startedAt: Date?
    private var ticker: Timer?

    /// Where this session writes.
    ///
    /// Injected rather than global: tests must not write into the user's real library, and a
    /// shared mutable static cannot express that safely while suites run in parallel.
    private let libraryRoot: URL?

    init(libraryRoot: URL? = nil) {
        self.libraryRoot = libraryRoot
    }

    @available(macOS 14.2, *)
    private var systemTap: SystemAudioTap? {
        get { systemTapStorage as? SystemAudioTap }
        set { systemTapStorage = newValue }
    }

    // MARK: - Control

    func start(sources: Sources = .all) throws {
        guard state != .recording else { throw SessionError.alreadyRecording }
        guard !sources.isEmpty else { throw SessionError.noSourcesSelected }

        // Checked before anything is created: a meeting that fills the volume half way through
        // corrupts the tail of a recording nobody can go back and repeat.
        if let availableMB = Self.availableDiskMB(), availableMB < Self.minimumFreeMB {
            throw SessionError.notEnoughDiskSpace(availableMB: availableMB)
        }

        let id = UUID()
        let started = Date()
        let folder = try Self.makeFolder(for: id, startedAt: started, in: libraryRoot)

        var engaged: Sources = []

        if sources.contains(.microphone) {
            let deviceID = AudioDeviceManager.shared.getCurrentDevice()
            guard deviceID != 0 else {
                try? FileManager.default.removeItem(at: folder)
                throw SessionError.noMicrophoneDevice
            }
            microphone.onAudioChunk = { [weak self] data in
                // Arrives on a Core Audio thread; the handlers are expected to be cheap.
                self?.onTranscriptionChunk?(data)
                self?.onMicrophoneChunk?(data)
            }
            do {
                try microphone.startRecording(toOutputFile: folder.appendingPathComponent("microphone.wav"), deviceID: deviceID)
                engaged.insert(.microphone)
            } catch {
                microphone.onAudioChunk = nil
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }

        if sources.contains(.systemAudio) {
            guard #available(macOS 14.2, *) else {
                if engaged.isEmpty {
                    try? FileManager.default.removeItem(at: folder)
                    throw SessionError.systemAudioUnavailable
                }
                logger.warning("System audio capture unavailable on this macOS; continuing with the microphone alone")
                finishStart(id: id, folder: folder, startedAt: started, sources: engaged)
                return
            }

            do {
                try systemWriter.open(at: folder.appendingPathComponent("system.wav"))
                systemWriter.onChunk = { [weak self] data in
                    self?.onTranscriptionChunk?(data)
                    self?.onSystemAudioChunk?(data)
                }

                let tap = SystemAudioTap()
                tap.onBuffer = { [weak systemWriter] buffer in
                    systemWriter?.append(buffer)
                }
                try tap.start()
                systemTap = tap
                engaged.insert(.systemAudio)
            } catch {
                systemWriter.onChunk = nil
                systemWriter.close()
                // A missing tap permission must not silently cost the user their microphone
                // track too — keep whatever is already running and surface the rest.
                if engaged.isEmpty {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
                logger.error("System audio capture failed, continuing with the microphone: \(error.localizedDescription, privacy: .public)")
            }
        }

        finishStart(id: id, folder: folder, startedAt: started, sources: engaged)
    }

    private func finishStart(id: UUID, folder: URL, startedAt: Date, sources: Sources) {
        recordingID = id
        self.folder = folder
        self.startedAt = startedAt
        activeSources = sources
        elapsed = 0
        state = .recording

        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common mode so the clock and levels keep moving while a menu or resize is tracking.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker

        logger.notice("Meeting recording started (\(sources.rawValue, privacy: .public)) at \(folder.lastPathComponent, privacy: .public)")
    }

    @discardableResult
    func stop() -> Recording? {
        guard state == .recording, let recordingID, let folder, let startedAt else { return nil }
        state = .stopping

        ticker?.invalidate()
        ticker = nil

        if activeSources.contains(.microphone) {
            microphone.stopRecording()
            microphone.onAudioChunk = nil
        }

        if activeSources.contains(.systemAudio), #available(macOS 14.2, *) {
            systemTap?.stop()
            systemTap = nil
            systemWriter.onChunk = nil
            systemWriter.close()
        }

        let recording = Recording(
            id: recordingID,
            folder: folder,
            startedAt: startedAt,
            duration: Date().timeIntervalSince(startedAt),
            microphoneTrack: activeSources.contains(.microphone)
                ? folder.appendingPathComponent("microphone.wav") : nil,
            systemAudioTrack: activeSources.contains(.systemAudio)
                ? folder.appendingPathComponent("system.wav") : nil
        )

        self.recordingID = nil
        self.folder = nil
        self.startedAt = nil
        activeSources = []
        microphoneLevelDb = -160
        systemAudioLevelDb = -160
        state = .idle

        logger.notice("Meeting recording stopped after \(recording.duration, privacy: .public)s")
        return recording
    }

    // MARK: - Metering

    private func tick() {
        guard state == .recording, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        microphoneLevelDb = activeSources.contains(.microphone) ? microphone.averagePower : -160
        systemAudioLevelDb = activeSources.contains(.systemAudio) ? systemWriter.averagePowerDb : -160

        // Give the call a few seconds of grace before suggesting anything is wrong.
        systemAudioSilent = activeSources.contains(.systemAudio)
            && elapsed > 5
            && !systemWriter.hasCapturedSignal
    }

    // MARK: - Storage

    /// Recordings live outside the transcript store on purpose: they are large, they are the
    /// user's raw material, and transcript retention must never delete them behind their back.
    /// Roughly four hours of two-track 16 kHz mono, plus headroom for the models.
    private static let minimumFreeMB = 1_024

    static func availableDiskMB() -> Int? {
        guard let root = try? recordingsRoot(),
              let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(available / 1_048_576)
    }

    static func recordingsRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = base.appendingPathComponent("Zerm/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// An imported recording gets a folder of the same shape as a recorded one, so nothing
    /// downstream has to know the difference.
    static func makeImportFolder(for id: UUID, startedAt: Date, in root: URL? = nil) throws -> URL {
        try makeFolder(for: id, startedAt: startedAt, in: root)
    }

    private static func makeFolder(for id: UUID, startedAt: Date, in root: URL?) throws -> URL {
        let stamp = startedAt.formatted(
            Date.FormatStyle()
                .year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                .locale(Locale(identifier: "en_US_POSIX"))
        )
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "")
        .replacingOccurrences(of: ", ", with: " ")
        .replacingOccurrences(of: " ", with: "_")

        let base = try root ?? recordingsRoot()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = base
            .appendingPathComponent("\(stamp)_\(id.uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
