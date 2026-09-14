import Foundation
import SwiftData
import os

/// JSON sidecars holding the structured transcript of a file transcription, stored beside its
/// History recording as `<transcription id>.segments.json`.
///
/// The History row keeps the speaker-labelled plain text; the sidecar keeps the timed segments
/// and speaker names the transcript viewer and exports need. Every path that deletes a
/// `Transcription` also removes its sidecar.
struct FileTranscriptStore: Sendable {
    let directory: URL

    /// `AppStoragePaths.root/Recordings`, where dictation audio also lives.
    static var recordings: FileTranscriptStore {
        FileTranscriptStore(directory: AppStoragePaths.root.appendingPathComponent("Recordings", isDirectory: true))
    }

    static func fileName(for transcriptionID: UUID) -> String {
        "\(transcriptionID.uuidString).segments.json"
    }

    func url(for transcriptionID: UUID) -> URL {
        directory.appendingPathComponent(Self.fileName(for: transcriptionID))
    }

    /// Where `FileTranscriptionHistory` keeps the transcribed file's audio.
    func audioURL(for transcriptionID: UUID) -> URL {
        directory.appendingPathComponent("\(transcriptionID.uuidString).wav")
    }

    func save(_ transcript: FileTranscript) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(transcript).write(to: url(for: transcript.transcriptionID), options: .atomic)
    }

    /// Whether a History row came from Transcribe File and can open its full transcript.
    func hasTranscript(for transcriptionID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: transcriptionID).path)
    }

    func load(_ transcriptionID: UUID) -> FileTranscript? {
        guard let data = try? Data(contentsOf: url(for: transcriptionID)) else { return nil }
        return try? JSONDecoder().decode(FileTranscript.self, from: data)
    }

    func remove(_ transcriptionID: UUID) {
        let url = url(for: transcriptionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Saves finished file transcripts into History: the converted audio moves into the recordings
/// folder so History playback works, the plain text goes into a `Transcription` row, and the
/// structured transcript into its sidecar.
@MainActor
struct FileTranscriptionHistory {
    let modelContext: ModelContext
    let store: FileTranscriptStore
    /// Posts the History notifications and records usage. Tests pass a no-op so they never
    /// touch the app's usage store or its cleanup observers.
    var didSave: @MainActor (Transcription) -> Void = { transcription in
        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
        UsageStatsService.shared.record(transcription)
    }

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "FileTranscriptionHistory")

    func save(_ transcript: FileTranscript, audio: URL, transcriptionDuration: TimeInterval) throws {
        let id = transcript.transcriptionID
        let audioDestination = store.audioURL(for: id)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: audioDestination.path) {
            try FileManager.default.removeItem(at: audioDestination)
        }
        try FileManager.default.moveItem(at: audio, to: audioDestination)

        let transcription = Transcription(
            text: transcript.plainText,
            duration: transcript.duration,
            audioFileURL: audioDestination.absoluteString,
            transcriptionModelName: transcript.modelName,
            transcriptionDuration: transcriptionDuration,
            transcriptionStatus: .completed
        )
        transcription.id = id

        do {
            try store.save(transcript)
        } catch {
            try? FileManager.default.removeItem(at: audioDestination)
            throw error
        }
        modelContext.insert(transcription)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(transcription)
            store.remove(id)
            try? FileManager.default.removeItem(at: audioDestination)
            throw error
        }
        didSave(transcription)
    }

    /// Writes speaker renames to the sidecar and the History text. A row the user already
    /// deleted stays deleted.
    func update(_ transcript: FileTranscript) {
        let id = transcript.transcriptionID
        do {
            var descriptor = FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let transcription = try modelContext.fetch(descriptor).first else { return }
            try store.save(transcript)
            transcription.text = transcript.plainText
            try modelContext.save()
        } catch {
            logger.error("Could not save speaker names: \(error.localizedDescription, privacy: .public)")
        }
    }
}
