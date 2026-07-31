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
        let folder: URL
        let startedAt: Date
        let duration: TimeInterval
        let microphoneTrack: URL?
        let systemAudioTrack: URL?
        let transcript: String?
        let speakerCount: Int
        let summary: MeetingSummarizer.Result?
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
            var start: TimeInterval
            var end: TimeInterval
            var text: String
            var speaker: String?
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
        // No sidecar means the recording never stopped cleanly. The journal is what is left.
        let recovered = sidecar == nil ? readJournal(in: folder) : []

        // A recording interrupted by a crash or a force quit has no sidecar. Rather than hide
        // it, fall back to what the audio files themselves can tell us — the tracks are intact
        // and still worth keeping.
        let started = sidecar?.startedAt
            ?? (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date.distantPast
        let duration = sidecar?.duration
            ?? Self.duration(of: hasMic ? mic : system)
            ?? 0

        return Item(
            id: folder.lastPathComponent,
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
            wasInterrupted: sidecar == nil
        )
    }

    // MARK: - Writing

    func writeSidecar(
        into folder: URL,
        startedAt: Date,
        duration: TimeInterval,
        segments: [MeetingTranscriber.Segment],
        speakerLabel: (MeetingTranscriber.Segment) -> String?,
        speakerCount: Int,
        summary: MeetingSummarizer.Result? = nil
    ) {
        let sidecar = Sidecar(
            startedAt: startedAt,
            duration: duration,
            transcript: segments.map(\.text).joined(separator: " "),
            speakerCount: speakerCount,
            segments: segments.map {
                Sidecar.Line(start: $0.start, end: $0.end, text: $0.text, speaker: speakerLabel($0))
            },
            summary: summary
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(sidecar).write(to: folder.appendingPathComponent(Self.sidecarName))
        } catch {
            logger.error("Could not write meeting sidecar: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Journal

    /// Appends one finished transcript line, immediately, as newline-delimited JSON.
    ///
    /// The sidecar is only written when a recording stops cleanly, which is exactly when it is
    /// least useful: a crash, a force quit or a power loss at minute 85 of a 90-minute meeting
    /// would leave two audio files and no transcript at all. Journalling each line as it lands
    /// costs one small append and makes the transcript recoverable up to the last window.
    nonisolated static func appendToJournal(in folder: URL, line: Sidecar.Line) {
        let url = folder.appendingPathComponent(journalName)
        guard let encoded = try? JSONEncoder().encode(line) else { return }
        var payload = encoded
        payload.append(0x0A)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url)
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
            case .unreadable(let name): return "Could not read audio from \(name)."
            case .emptyAudio: return "That file contains no audio."
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
}
