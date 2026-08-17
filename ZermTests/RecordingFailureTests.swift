import Foundation
import Testing
@testable import Zerm

struct RecordingFailureTests {

    @Test @MainActor func missingAudioRetentionKeyIsNotZeroDays() {
        let defaults = UserDefaults(suiteName: "zerm.tests.audio.retention.\(UUID().uuidString)")!
        #expect(AudioCleanupManager.effectiveRetentionDays(defaults: defaults) == 14)
    }

    @Test @MainActor func explicitZeroRetentionIsHonouredAsNoSweep() {
        let defaults = UserDefaults(suiteName: "zerm.tests.audio.retention.\(UUID().uuidString)")!
        defaults.set(0, forKey: "AudioRetentionPeriod")
        #expect(AudioCleanupManager.effectiveRetentionDays(defaults: defaults) == 0)
    }

    @Test @MainActor func cocoaFileMissingIsNotAGenericOperationFailed() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed."
        ])
        let message = TranscriptionPipeline.describeTranscriptionFailure(error)
        #expect(message.contains("could not be opened") || message.contains("retry"))
        #expect(!message.hasPrefix("The operation could not be completed"))
    }

    @Test @MainActor func genericCocoaInterruptNamesTheTimeoutAndKeepsTheFile() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed"]
        )
        let message = TranscriptionPipeline.describeTranscriptionFailure(error)
        #expect(message.contains("interrupted") || message.contains("timeout"))
        #expect(message.contains("History") || message.contains("Recordings"))
    }

    @Test func wavDurationComesFromBytesNotAVFoundation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-durability-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writePCMWav(frames: 16000 * 3, to: url)

        let inspection = RecordingAudioStore.inspect(url)
        #expect(inspection != nil)
        #expect(inspection?.hasAudio == true)
        #expect(abs((inspection?.duration ?? 0) - 3.0) < 0.01)
    }

    @Test func headerOnlyWavIsNotTreatableAsAudio() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-header-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writePCMWav(frames: 0, to: url)

        let inspection = RecordingAudioStore.inspect(url)
        #expect(inspection?.hasAudio == false)
    }

    @Test func failedAndPendingAudioIsNeverEligibleForSweep() {
        #expect(RecordingAudioStore.shouldPreserveAudio(status: TranscriptionStatus.failed.rawValue))
        #expect(RecordingAudioStore.shouldPreserveAudio(status: TranscriptionStatus.pending.rawValue))
        #expect(!RecordingAudioStore.shouldPreserveAudio(status: TranscriptionStatus.completed.rawValue))
    }

    @Test func orphanSweepKeepsYoungUnreferencedFiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-orphan-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writePCMWav(frames: 1600, to: url)

        #expect(RecordingAudioStore.isWithinOrphanGrace(url, grace: 24 * 60 * 60))
        #expect(!RecordingAudioStore.isWithinOrphanGrace(
            url,
            grace: 24 * 60 * 60,
            now: Date().addingTimeInterval(25 * 60 * 60)
        ))
    }

    private static func writePCMWav(frames: Int, to url: URL) throws {
        let dataBytes = frames * 2
        var data = Data()
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(UInt32(36 + dataBytes))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(16000)
        appendUInt32(32000)
        appendUInt16(2)
        appendUInt16(16)
        data.append(contentsOf: "data".utf8)
        appendUInt32(UInt32(dataBytes))
        data.append(Data(count: dataBytes))
        try data.write(to: url)
    }
}
