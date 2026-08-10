@preconcurrency import AVFoundation
import Foundation
import OSLog

/// The recordings already on disk.
///
/// Deliberately filesystem-backed rather than another SwiftData store: a recording *is* its
/// folder, so the folder is the record. Nothing can drift out of sync, transcript retention can
/// never reach it, and a user who moves or deletes a folder in Finder gets exactly what they
/// expect. The sidecar JSON holds only what cannot be recovered from the audio itself.
@MainActor
final class MeetingRecordingStore: ObservableObject {

    struct Item: Identifiable, Equatable, Hashable {
        let id: String
        let sessionID: UUID?
        let folder: URL
        let startedAt: Date
        let duration: TimeInterval
        let microphoneTrack: URL?
        let systemAudioTrack: URL?
        let transcript: String?
        let speakerCount: Int
        let summary: MeetingSummarizer.Result?
        let transcriptionSnapshot: MeetingTranscriptionSnapshot?
        let sourceHealth: [String: MeetingSourceHealth]
        let issues: [MeetingRecordingIssue]
        /// Recovered from the journal because the recording never stopped cleanly.
        let wasInterrupted: Bool

        var title: String {
            startedAt.formatted(date: .abbreviated, time: .shortened)
        }

        /// Hashed on the folder name alone. It is the recording's identity on disk, and the
        /// derived fields — summary, transcript — are not worth hashing to distinguish rows.
        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        var totalBytes: Int64 {
            [microphoneTrack, systemAudioTrack]
                .compactMap { $0 }
                .reduce(into: Int64(0)) { total, url in
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                    total += (attributes?[.size] as? Int64) ?? 0
                }
        }
    }

    /// What gets written beside the audio so a recording can be reopened later.
    struct Sidecar: Codable {
        var startedAt: Date
        var duration: TimeInterval
        var transcript: String
        var speakerCount: Int
        var segments: [Line]
        var summary: MeetingSummarizer.Result?

        struct Line: Codable {
            var source: MeetingAudioSource? = nil
            var start: TimeInterval
            var end: TimeInterval
            var text: String
            var speaker: String?
            var speakerConfidence: String? = nil
        }
    }

    /// Durable, versioned state for capture and processing. `meeting.json` remains the content
    /// sidecar so existing libraries stay readable; this manifest records how those contents
    /// were produced and whether recovery or another processing pass is needed.
    struct Manifest: Codable, Equatable {
        static let currentSchemaVersion = 3

        enum Status: String, Codable {
            case recording
            case processing
            case ready
            case partial
            case interrupted
            case failed
            case imported
        }

        enum JobStatus: String, Codable {
            case notRequested, pending, running, complete, failed, unavailable
        }

        enum TranscriptionCoverageStrategy: String, Codable {
            /// Every saved local track was processed sequentially after Stop.
            case canonicalLocalTracks
            /// Durable live cloud windows were reused and only uncovered ranges were retried.
            case liveCloudCoverageWithGapRetry
            /// No live cloud coverage existed, so the saved tracks were processed once after Stop.
            case canonicalCloudTracks
        }

        struct Track: Codable, Equatable {
            var source: MeetingAudioSource
            var fileName: String
            var startOffset: TimeInterval
            var duration: TimeInterval
            var frames: Int64
            var clockAnchors: [MeetingClockAnchor] = []

            init(
                source: MeetingAudioSource,
                fileName: String,
                startOffset: TimeInterval,
                duration: TimeInterval,
                frames: Int64,
                clockAnchors: [MeetingClockAnchor] = []
            ) {
                self.source = source
                self.fileName = fileName
                self.startOffset = startOffset
                self.duration = duration
                self.frames = frames
                self.clockAnchors = clockAnchors
            }

            private enum CodingKeys: String, CodingKey {
                case source, fileName, startOffset, duration, frames, clockAnchors
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                source = try container.decode(MeetingAudioSource.self, forKey: .source)
                fileName = try container.decode(String.self, forKey: .fileName)
                startOffset = try container.decode(TimeInterval.self, forKey: .startOffset)
                duration = try container.decode(TimeInterval.self, forKey: .duration)
                frames = try container.decode(Int64.self, forKey: .frames)
                clockAnchors = try container.decodeIfPresent(
                    [MeetingClockAnchor].self,
                    forKey: .clockAnchors
                ) ?? [
                    .init(
                        fileFrame: 0,
                        meetingTime: startOffset,
                        hostTimeNanos: nil,
                        sourceSampleTime: nil
                    )
                ]
            }
        }

        var schemaVersion: Int
        var sessionID: UUID
        var startedAt: Date
        var endedAt: Date?
        var status: Status
        var duration: TimeInterval
        var captureTarget: MeetingCaptureTarget
        var requestedSources: [MeetingAudioSource]
        var tracks: [Track]
        var transcriptionSnapshot: MeetingTranscriptionSnapshot?
        var transcriptionStatus: JobStatus
        var diarizationStatus: JobStatus
        var sourceHealth: [String: MeetingSourceHealth]
        var issues: [MeetingRecordingIssue]
        var importedFileName: String?
        var transcriptionGaps: [MeetingTranscriber.Gap]?
        var transcriptionCoverageStrategy: TranscriptionCoverageStrategy?
        var summarySnapshot: MeetingSummarySnapshot?
        var summaryStatus: JobStatus?

        init(
            schemaVersion: Int = currentSchemaVersion,
            sessionID: UUID,
            startedAt: Date,
            endedAt: Date? = nil,
            status: Status,
            duration: TimeInterval = 0,
            captureTarget: MeetingCaptureTarget,
            requestedSources: [MeetingAudioSource],
            tracks: [Track] = [],
            transcriptionSnapshot: MeetingTranscriptionSnapshot? = nil,
            transcriptionStatus: JobStatus = .notRequested,
            diarizationStatus: JobStatus = .notRequested,
            sourceHealth: [String: MeetingSourceHealth] = [:],
            issues: [MeetingRecordingIssue] = [],
            importedFileName: String? = nil,
            transcriptionGaps: [MeetingTranscriber.Gap]? = nil,
            transcriptionCoverageStrategy: TranscriptionCoverageStrategy? = nil,
            summarySnapshot: MeetingSummarySnapshot? = nil,
            summaryStatus: JobStatus? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.sessionID = sessionID
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.status = status
            self.duration = duration
            self.captureTarget = captureTarget
            self.requestedSources = requestedSources
            self.tracks = tracks
            self.transcriptionSnapshot = transcriptionSnapshot
            self.transcriptionStatus = transcriptionStatus
            self.diarizationStatus = diarizationStatus
            self.sourceHealth = sourceHealth
            self.issues = issues
            self.importedFileName = importedFileName
            self.transcriptionGaps = transcriptionGaps
            self.transcriptionCoverageStrategy = transcriptionCoverageStrategy
            self.summarySnapshot = summarySnapshot
            self.summaryStatus = summaryStatus
        }
    }

    @Published private(set) var items: [Item] = []

    /// Where this store looks. Injected so tests never touch the user's real library.
    private let libraryRoot: URL?

    init(libraryRoot: URL? = nil) {
        self.libraryRoot = libraryRoot
    }

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingRecordingStore")
    private static let sidecarName = "meeting.json"
    nonisolated static let manifestName = "manifest.json"
    nonisolated fileprivate static let journalName = "transcript.jsonl"

    func reload() {
        guard let root = libraryRoot ?? (try? MeetingRecordingSession.recordingsRoot()) else {
            items = []
            return
        }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        items = folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { item(at: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func item(at folder: URL) -> Item? {
        let mic = folder.appendingPathComponent("microphone.wav")
        let system = folder.appendingPathComponent("system.wav")
        let hasMic = FileManager.default.fileExists(atPath: mic.path)
        let hasSystem = FileManager.default.fileExists(atPath: system.path)
        guard hasMic || hasSystem else { return nil }

        let sidecar = readSidecar(in: folder)
        let manifest = readManifest(in: folder)
        // No sidecar means the recording never stopped cleanly. The journal is what is left.
        let recovered = sidecar == nil ? readJournal(in: folder) : []

        // A recording interrupted by a crash or a force quit has no sidecar. Rather than hide
        // it, fall back to what the audio files themselves can tell us — the tracks are intact
        // and still worth keeping.
        let started = manifest?.startedAt
            ?? sidecar?.startedAt
            ?? (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date.distantPast
        let audioDuration = [hasMic ? mic : nil, hasSystem ? system : nil]
            .compactMap { $0 }
            .compactMap { Self.duration(of: $0) }
            .max()
        let trackDuration = manifest?.tracks.map {
            max(0, $0.startOffset) + max(0, $0.duration)
        }.max()
        let durableEvidence = [audioDuration, trackDuration].compactMap { $0 }.max()
        let persistedDuration = [manifest?.duration, sidecar?.duration]
            .compactMap { $0 }
            .first { $0.isFinite && $0 > 0 }
        let duration = Self.reconciledDuration(
            persisted: persistedDuration,
            trackOrAudioEvidence: durableEvidence
        )

        return Item(
            id: folder.lastPathComponent,
            sessionID: manifest?.sessionID,
            folder: folder,
            startedAt: started,
            duration: duration,
            microphoneTrack: hasMic ? mic : nil,
            systemAudioTrack: hasSystem ? system : nil,
            transcript: sidecar?.transcript
                ?? (recovered.isEmpty ? nil : recovered.map(\.text).joined(separator: " ")),
            speakerCount: sidecar?.speakerCount
                ?? Set(recovered.compactMap(\.speaker)).count,
            summary: sidecar?.summary,
            transcriptionSnapshot: manifest?.transcriptionSnapshot,
            sourceHealth: manifest?.sourceHealth ?? [:],
            issues: manifest?.issues ?? [],
            wasInterrupted: manifest.map { [.recording, .processing, .interrupted].contains($0.status) }
                ?? (sidecar == nil)
        )
    }

    // MARK: - Writing

    @discardableResult
    func writeSidecar(
        into folder: URL,
        startedAt: Date,
        duration: TimeInterval,
        segments: [MeetingTranscriber.Segment],
        speakerLabel: (MeetingTranscriber.Segment) -> String?,
        speakerCount: Int,
        summary: MeetingSummarizer.Result? = nil
    ) -> Bool {
        let sidecar = Sidecar(
            startedAt: startedAt,
            duration: duration,
            transcript: segments.map(\.text).joined(separator: " "),
            speakerCount: speakerCount,
            segments: segments.map {
                Sidecar.Line(
                    source: $0.source,
                    start: $0.start,
                    end: $0.end,
                    text: $0.text,
                    speaker: speakerLabel($0),
                    speakerConfidence: $0.speakerConfidence.rawValue
                )
            },
            summary: summary
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(sidecar).write(
                to: folder.appendingPathComponent(Self.sidecarName),
                options: .atomic
            )
            return true
        } catch {
            logger.error("Could not write meeting sidecar: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Journal

    /// Appends one finished transcript line, immediately, as newline-delimited JSON.
    ///
    /// The sidecar is only written when a recording stops cleanly, which is exactly when it is
    /// least useful: a crash, a force quit or a power loss at minute 85 of a 90-minute meeting
    /// would leave two audio files and no transcript at all. Journalling each line as it lands
    /// costs one small append and makes the transcript recoverable up to the last window.
    @discardableResult
    nonisolated static func appendToJournal(in folder: URL, line: Sidecar.Line) -> Bool {
        let url = folder.appendingPathComponent(journalName)
        guard let encoded = try? JSONEncoder().encode(line) else { return false }
        var payload = encoded
        payload.append(0x0A)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: payload)
                return true
            } catch {
                return false
            }
        } else {
            do {
                try payload.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    /// Lines recovered from an interrupted recording.
    func readJournal(in folder: URL) -> [Sidecar.Line] {
        let url = folder.appendingPathComponent(Self.journalName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text
            .split(separator: "\n")
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(Sidecar.Line.self, from: data)
            }
    }

    func readSidecar(in folder: URL) -> Sidecar? {
        let url = folder.appendingPathComponent(Self.sidecarName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Sidecar.self, from: data)
    }

    nonisolated static func writeManifest(_ manifest: Manifest, into folder: URL) throws {
        var upgradedManifest = manifest
        // Every rewrite is also a schema migration. This prevents a recovered v2 manifest from
        // acquiring v3 fields while continuing to claim the older contract version.
        upgradedManifest.schemaVersion = Manifest.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(upgradedManifest).write(
            to: folder.appendingPathComponent(manifestName),
            options: .atomic
        )
    }

    func readManifest(in folder: URL) -> Manifest? {
        Self.readManifest(in: folder)
    }

    nonisolated static func readManifest(in folder: URL) -> Manifest? {
        let url = folder.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    // MARK: - Import

    /// File types the recorder can adopt.
    ///
    /// Anything AVFoundation can decode, converted on import to the same 16 kHz mono the
    /// recorder produces — so an imported file and a recorded one are indistinguishable
    /// downstream, and transcription, diarisation and summarising all work on it unchanged.
    static let importableExtensions = ["wav", "mp3", "m4a", "mp4", "flac", "ogg", "aac", "caf", "aiff"]

    enum ImportError: LocalizedError {
        case unreadable(String)
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                let format = String(localized: "Could not read audio from %@.")
                return String.localizedStringWithFormat(format, name)
            case .emptyAudio:
                return String(localized: "That file contains no audio.")
            }
        }
    }

    /// Copies an existing recording into the library as its own meeting folder.
    @discardableResult
    func importRecording(from source: URL, startedAt: Date = Date()) throws -> Item {
        let asset = try AVAudioFile(forReading: source)
        guard asset.length > 0 else { throw ImportError.emptyAudio }

        let id = UUID()
        let folder = try MeetingRecordingSession.makeImportFolder(for: id, startedAt: startedAt, in: libraryRoot)
        let destination = folder.appendingPathComponent("microphone.wav")

        try Self.convertToRecorderFormat(from: asset, to: destination)

        let duration = Double(asset.length) / asset.fileFormat.sampleRate
        let manifest = Manifest(
            sessionID: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            status: .imported,
            duration: duration,
            captureTarget: .allSystemAudio,
            requestedSources: [.imported],
            tracks: [
                .init(
                    source: .imported,
                    fileName: destination.lastPathComponent,
                    startOffset: 0,
                    duration: duration,
                    frames: Int64((duration * SystemAudioTrackWriter.targetFormat.sampleRate).rounded()),
                    clockAnchors: [
                        .init(fileFrame: 0, meetingTime: 0, hostTimeNanos: nil, sourceSampleTime: nil)
                    ]
                )
            ],
            transcriptionStatus: .pending,
            diarizationStatus: .pending,
            sourceHealth: [MeetingAudioSource.imported.rawValue: .init(status: .stopped)],
            importedFileName: source.lastPathComponent
        )
        try Self.writeManifest(manifest, into: folder)

        guard let item = item(at: folder) else {
            try? FileManager.default.removeItem(at: folder)
            throw ImportError.unreadable(source.lastPathComponent)
        }
        reload()
        logger.notice("Imported \(source.lastPathComponent, privacy: .public)")
        return item
    }

    /// Streams through the file rather than loading it whole: an imported two-hour recording
    /// must not have to fit in memory.
    private static func convertToRecorderFormat(from source: AVAudioFile, to destination: URL) throws {
        let target = SystemAudioTrackWriter.targetFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: target.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard let converter = AVAudioConverter(from: source.processingFormat, to: target) else {
            throw ImportError.unreadable(source.url.lastPathComponent)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let chunkFrames: AVAudioFrameCount = 16_384
        let ratio = target.sampleRate / source.processingFormat.sampleRate

        while source.framePosition < source.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunkFrames) else { break }
            try source.read(into: input)
            guard input.frameLength > 0 else { break }

            let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }

            var error: NSError?
            // The input block is called synchronously by `convert`, so a nonisolated box is
            // enough to hand the buffer across without it being captured as shared state.
            let pending = ConversionInput(buffer: input)
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                guard let next = pending.take() else { outStatus.pointee = .noDataNow; return nil }
                outStatus.pointee = .haveData
                return next
            }
            guard status != .error, converted.frameLength > 0 else { continue }
            try output.write(from: converted)
        }
    }

    /// One-shot holder for a buffer handed to `AVAudioConverter`'s pull block.
    private final class ConversionInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    // MARK: - Management

    func delete(_ item: Item) {
        do {
            try FileManager.default.trashItem(at: item.folder, resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
        } catch {
            logger.error("Could not delete recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Reconciles legacy wall-clock durations with evidence that survives a clock jump. A normal
    /// meeting may contain a silent tail, so modest excess is retained. A duration that is more
    /// than both five minutes and one full evidence-length beyond the tracks is treated as a bad
    /// wall-clock interval and cannot override the captured files.
    nonisolated static func reconciledDuration(
        persisted: TimeInterval?,
        trackOrAudioEvidence evidence: TimeInterval?
    ) -> TimeInterval {
        let validPersisted = persisted.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let validEvidence = evidence.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard let evidence = validEvidence else { return validPersisted ?? 0 }
        guard let persisted = validPersisted else { return evidence }
        if persisted < evidence { return evidence }
        let toleratedSilentTail = max(300, evidence)
        return persisted - evidence > toleratedSilentTail ? evidence : persisted
    }
}
