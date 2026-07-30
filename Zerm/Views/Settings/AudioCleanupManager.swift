import Foundation
import SwiftData
import os

/// A utility class that manages automatic cleanup of audio files while preserving transcript data.
///
/// Main-actor isolated: every method touches the SwiftData `ModelContext` and the
/// `Transcription` models it vends, neither of which is `Sendable`. The class used to
/// hop through `MainActor.run` per call site, which hid those non-Sendable captures
/// behind a closure boundary the compiler flagged.
@MainActor
class AudioCleanupManager {
    static let shared = AudioCleanupManager()

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "audio.cleanup")
    private var cleanupTimer: Timer?
    private var modelContext: ModelContext?
    
    // Default cleanup settings
    private let defaultRetentionDays = 7
    private let cleanupCheckInterval: TimeInterval = 86400 // Check once per day (in seconds)
    
    private init() {}
    
    /// Start the automatic cleanup process
    func startAutomaticCleanup(modelContext: ModelContext) {
        // Cancel any existing timer
        cleanupTimer?.invalidate()

        // Held on the main actor rather than captured by the timer closure: the
        // closure is @Sendable and ModelContext is not Sendable.
        self.modelContext = modelContext

        // Perform initial cleanup
        Task {
            await performCleanup(modelContext: modelContext)
        }

        // Schedule regular cleanup
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupCheckInterval, repeats: true) { _ in
            Task { @MainActor in
                let manager = AudioCleanupManager.shared
                guard let context = manager.modelContext else { return }
                await manager.performCleanup(modelContext: context)
            }
        }
    }
    
    /// Stop the automatic cleanup process
    func stopAutomaticCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }
    
    /// Get information about the files that would be cleaned up
    func getCleanupInfo(modelContext: ModelContext) async -> (fileCount: Int, totalSize: Int64, transcriptions: [Transcription]) {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: "AudioRetentionPeriod")

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return (0, 0, [])
        }

        do {
            let descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate<Transcription> { transcription in
                    transcription.timestamp < cutoffDate &&
                    transcription.audioFileURL != nil
                }
            )

            let transcriptions = try modelContext.fetch(descriptor)

            var fileCount = 0
            var totalSize: Int64 = 0
            var eligibleTranscriptions: [Transcription] = []

            for transcription in transcriptions {
                if let urlString = transcription.audioFileURL,
                   let url = URL(string: urlString),
                   FileManager.default.fileExists(atPath: url.path) {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let fileSize = attributes[.size] as? Int64 {
                        totalSize += fileSize
                        fileCount += 1
                        eligibleTranscriptions.append(transcription)
                    }
                }
            }

            return (fileCount, totalSize, eligibleTranscriptions)
        } catch {
            logger.error("Failed to gather audio cleanup info: \(error.localizedDescription, privacy: .public)")
            return (0, 0, [])
        }
    }
    
    /// Perform the cleanup operation
    private func performCleanup(modelContext: ModelContext) async {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: "AudioRetentionPeriod")

        // Check if automatic cleanup is enabled
        let isCleanupEnabled = UserDefaults.standard.bool(forKey: "IsAudioCleanupEnabled")
        guard isCleanupEnabled else { return }

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return
        }

        do {
            let descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate<Transcription> { transcription in
                    transcription.timestamp < cutoffDate &&
                    transcription.audioFileURL != nil
                }
            )

            let transcriptions = try modelContext.fetch(descriptor)
            var deletedCount = 0

            for transcription in transcriptions {
                if let urlString = transcription.audioFileURL,
                   let url = URL(string: urlString),
                   FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        transcription.audioFileURL = nil
                        deletedCount += 1
                    } catch {
                        // Leave audioFileURL pointing at the file we could not remove.
                        logger.error("Scheduled cleanup could not delete an audio file: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            if deletedCount > 0 {
                try modelContext.save()
                logger.notice("Scheduled cleanup removed \(deletedCount, privacy: .public) audio files")
            }
        } catch {
            // Non-critical, but staying silent here is why stale audio could pile up
            // unnoticed — record it.
            logger.error("Scheduled audio cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Run cleanup manually - can be called from settings
    func runManualCleanup(modelContext: ModelContext) async {
        await performCleanup(modelContext: modelContext)
    }
    
    /// Run cleanup on the specified transcriptions
    func runCleanupForTranscriptions(modelContext: ModelContext, transcriptions: [Transcription]) -> (deletedCount: Int, errorCount: Int) {
        var deletedCount = 0
        var errorCount = 0

        for transcription in transcriptions {
            if let urlString = transcription.audioFileURL,
               let url = URL(string: urlString),
               FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                    transcription.audioFileURL = nil
                    deletedCount += 1
                } catch {
                    logger.error("Failed to delete audio file: \(error.localizedDescription, privacy: .public)")
                    errorCount += 1
                }
            }
        }

        if deletedCount > 0 || errorCount > 0 {
            do {
                try modelContext.save()
            } catch {
                // The files are gone but the rows still point at them; say so rather
                // than reporting a clean sweep.
                logger.error("Audio cleanup succeeded on disk but the context failed to save: \(error.localizedDescription, privacy: .public)")
                errorCount += deletedCount
                deletedCount = 0
            }
        }

        return (deletedCount, errorCount)
    }
    
    /// Format file size in human-readable form
    func formatFileSize(_ size: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: size)
    }
} 
