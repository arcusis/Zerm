import Foundation
import os

/// Deletes everything the Meetings module left behind. Meetings was removed in 2.8.6.
///
/// Meeting sessions were folders of WAV tracks, manifests, journals and transcript sidecars in
/// `Application Support/Zerm/Recordings`. Nothing in the app can open them any more, so they are
/// deleted, together with the meeting preferences. This never touches the custom sounds that
/// share the legacy folder, or dictation audio in `AppStoragePaths.root/Recordings`.
///
/// Safe to delete once all users have updated past 2.8.6.
enum MeetingDataRemovalMigration {
    static let completionKey = "meeting-data-removal-migration-v1-completed"

    static let removedDefaultsKeys = [
        "meetingAutoDetect",
        "meetingCaptureApplicationBundleID",
        "meetingCaptureMicrophone",
        "meetingCaptureSystemAudio",
        "meetingCaptureTargetMode",
        "meetingIdentifySpeakers",
        "meetingLiveTranscript",
        "meetingSummarise",
        "sidebarMeetingsExpanded",
        "systemAudioCaptureVerificationToken",
        "systemAudioCaptureVerifiedAt"
    ]

    /// `defaults` and `legacyRoot` are injectable so tests never mark the real install as
    /// migrated, and never delete anything outside a temporary directory.
    static func run(defaults: UserDefaults = .standard, legacyRoot: URL = AppStoragePaths.legacyRoot) {
        guard !defaults.bool(forKey: completionKey) else { return }

        let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingDataRemovalMigration")

        for key in removedDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        if defaults.string(forKey: "selectedSettingsPane") == "meetings" {
            defaults.removeObject(forKey: "selectedSettingsPane")
        }

        let recordings = legacyRoot.appendingPathComponent("Recordings", isDirectory: true)
        if FileManager.default.fileExists(atPath: recordings.path) {
            let reclaimedBytes = allocatedSize(of: recordings)
            do {
                try FileManager.default.removeItem(at: recordings)
                let megabytes = Double(reclaimedBytes) / 1_048_576
                logger.notice("Removed meeting recordings, reclaimed \(String(format: "%.1f", megabytes), privacy: .public) MB")
            } catch {
                // Leave the flag unset so the next launch tries again.
                logger.error("Could not remove meeting recordings: \(error.localizedDescription, privacy: .private)")
                return
            }
        }

        defaults.set(true, forKey: completionKey)
    }

    private static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
