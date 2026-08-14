import Foundation
import SwiftData
import OSLog

@MainActor
final class TranscriptionAutoCleanupService {
    static let shared = TranscriptionAutoCleanupService()

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TranscriptionAutoCleanupService")
    private var modelContext: ModelContext?

    nonisolated private static let keyIsEnabled = "IsTranscriptionCleanupEnabled"
    private let keyRetentionMinutes = "TranscriptionRetentionMinutes"

    private let defaultRetentionMinutes: Int = 24 * 60

    /// An unset key must not read as 0: `integer(forKey:)` returns 0 for a missing value,
    /// which reads as "Immediately" and wiped the entire history. An explicit 0 is the
    /// user actually picking "Immediately" and is honoured.
    private var retentionMinutes: Int {
        (UserDefaults.standard.object(forKey: keyRetentionMinutes) as? Int) ?? defaultRetentionMinutes
    }

    private var recordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
            .appendingPathComponent("Recordings")
    }

    private init() {}

    func startMonitoring(modelContext: ModelContext) {
        self.modelContext = modelContext

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscriptionCompleted(_:)),
            name: .transcriptionCompleted,
            object: nil
        )

        if UserDefaults.standard.bool(forKey: Self.keyIsEnabled) {
            let modelContainer = modelContext.container
            let effectiveMinutes = max(retentionMinutes, 0)
            let recordingsDirectory = recordingsDirectory
            Task.detached(priority: .utility) {
                await Self.sweepOldTranscriptions(
                    modelContainer: modelContainer,
                    effectiveMinutes: effectiveMinutes
                )
                await Self.cleanupOrphanAudioFiles(
                    modelContainer: modelContainer,
                    recordingsDirectory: recordingsDirectory
                )
            }
        }
    }

    func stopMonitoring() {
        NotificationCenter.default.removeObserver(self, name: .transcriptionCompleted, object: nil)
    }

    func runManualCleanup(modelContext: ModelContext) async {
        let modelContainer = modelContext.container
        let effectiveMinutes = max(retentionMinutes, 0)
        await Task.detached(priority: .utility) {
            await Self.sweepOldTranscriptions(
                modelContainer: modelContainer,
                effectiveMinutes: effectiveMinutes
            )
        }.value
    }

    @objc private func handleTranscriptionCompleted(_ notification: Notification) {
        let isEnabled = UserDefaults.standard.bool(forKey: Self.keyIsEnabled)
        guard isEnabled else { return }

        if retentionMinutes > 0 {
            if let modelContext = self.modelContext {
                let modelContainer = modelContext.container
                let effectiveMinutes = max(retentionMinutes, 0)
                Task.detached(priority: .utility) {
                    await Self.sweepOldTranscriptions(
                        modelContainer: modelContainer,
                        effectiveMinutes: effectiveMinutes
                    )
                }
            }
            return
        }

        guard let transcription = notification.object as? Transcription,
              let modelContext = self.modelContext else {
            logger.error("Invalid transcription or missing model context")
            return
        }

        if let urlString = transcription.audioFileURL,
           let url = URL(string: urlString) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.error("Failed to delete audio file: \(error.localizedDescription, privacy: .public)")
            }
        }

        modelContext.delete(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
        } catch {
            logger.error("Failed to save after transcription deletion: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func sweepOldTranscriptions(
        modelContainer: ModelContainer,
        effectiveMinutes: Int
    ) async {
        guard UserDefaults.standard.bool(forKey: Self.keyIsEnabled) else {
            return
        }

        let cutoffDate = Date().addingTimeInterval(TimeInterval(-effectiveMinutes * 60))
        let logger = Logger(subsystem: "com.arcusis.zerm", category: "TranscriptionAutoCleanupService")

        do {
            let backgroundContext = ModelContext(modelContainer)

            let descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate<Transcription> { transcription in
                    transcription.timestamp < cutoffDate
                }
            )
            let items = try backgroundContext.fetch(descriptor)
            var deletedCount = 0
            for transcription in items {
                if let urlString = transcription.audioFileURL,
                   let url = URL(string: urlString),
                   FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                backgroundContext.delete(transcription)
                deletedCount += 1
            }
            if deletedCount > 0 {
                try backgroundContext.save()
                logger.notice("Cleaned up \(deletedCount, privacy: .public) old transcription(s)")
                await MainActor.run {
                    NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                }
            }
        } catch {
            logger.error("Failed during transcription cleanup: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes audio files in Recordings directory that have no corresponding Transcription record
    nonisolated private static func cleanupOrphanAudioFiles(
        modelContainer: ModelContainer,
        recordingsDirectory: URL
    ) async {
        guard UserDefaults.standard.bool(forKey: Self.keyIsEnabled) else {
            return
        }

        let logger = Logger(subsystem: "com.arcusis.zerm", category: "TranscriptionAutoCleanupService")

        do {
            let backgroundContext = ModelContext(modelContainer)

            var descriptor = FetchDescriptor<Transcription>()
            descriptor.propertiesToFetch = [\.audioFileURL]

            let transcriptions = try backgroundContext.fetch(descriptor)
            let referencedFiles = Set(transcriptions.compactMap { transcription -> String? in
                guard let urlString = transcription.audioFileURL,
                      let url = URL(string: urlString) else { return nil }
                return url.lastPathComponent
            })

            guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else { return }
            let filesInDirectory = try FileManager.default.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: nil
            )

            var deletedCount = 0
            for fileURL in filesInDirectory {
                let fileName = fileURL.lastPathComponent
                if !referencedFiles.contains(fileName) {
                    try? FileManager.default.removeItem(at: fileURL)
                    deletedCount += 1
                }
            }

            if deletedCount > 0 {
                logger.notice("Cleaned up \(deletedCount, privacy: .public) orphan audio file(s)")
            }
        } catch {
            logger.error("Failed during orphan audio cleanup: \(error.localizedDescription, privacy: .public)")
        }
    }
}
