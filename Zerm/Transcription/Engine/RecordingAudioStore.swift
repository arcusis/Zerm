import Foundation

/// Owns the on-disk recording file. Transcription and enhancement may fail;
/// the WAV must still be there so History can retry.
enum RecordingAudioStore {
    static let wavHeaderBytes: Int64 = 44
    static let orphanGrace: TimeInterval = 24 * 60 * 60

    struct Inspection: Equatable {
        let url: URL
        let byteCount: Int64
        let duration: TimeInterval

        var hasAudio: Bool { byteCount > RecordingAudioStore.wavHeaderBytes && duration > 0 }
    }

    /// Flush file metadata after ExtAudioFileDispose so a reader cannot open a
    /// half-written WAV (History 14155 / 14161).
    static func synchronize(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            if #available(macOS 11.0, *) {
                try handle.synchronize()
            } else {
                handle.synchronizeFile()
            }
        } catch {
            // Best-effort. Inspect still runs on whatever landed on disk.
        }
    }

    static func inspect(_ url: URL) -> Inspection? {
        synchronize(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let duration = durationFromWAV(url) ?? 0
        return Inspection(url: url, byteCount: byteCount, duration: duration)
    }

    /// PCM duration from the WAV header. Does not open AVAudioFile, so it is
    /// safe immediately after the writer closes.
    static func durationFromWAV(_ url: URL) -> TimeInterval? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= 44,
              data.starts(with: Data("RIFF".utf8)),
              data[8..<12] == Data("WAVE".utf8)
        else { return nil }

        var offset = 12
        var sampleRate: UInt32 = 0
        var channels: UInt16 = 0
        var bitsPerSample: UInt16 = 0
        var dataBytes: UInt32 = 0

        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let chunkSize = data.uInt32LE(at: offset + 4)
            let payload = offset + 8
            if chunkID == "fmt ", payload + 16 <= data.count {
                channels = data.uInt16LE(at: payload + 2)
                sampleRate = data.uInt32LE(at: payload + 4)
                bitsPerSample = data.uInt16LE(at: payload + 14)
            } else if chunkID == "data" {
                dataBytes = chunkSize
                break
            }
            let advance = 8 + Int(chunkSize) + (Int(chunkSize) % 2)
            guard advance > 0 else { break }
            offset += advance
        }

        let bytesPerSecond = Int(sampleRate) * Int(channels) * Int(bitsPerSample) / 8
        guard bytesPerSecond > 0, dataBytes > 0 else { return nil }
        return TimeInterval(dataBytes) / TimeInterval(bytesPerSecond)
    }

    static func shouldPreserveAudio(status: String?) -> Bool {
        status == TranscriptionStatus.pending.rawValue
            || status == TranscriptionStatus.failed.rawValue
    }

    /// Orphan sweep must not delete a take whose History row is still being written.
    static func isWithinOrphanGrace(
        _ url: URL,
        grace: TimeInterval = orphanGrace,
        now: Date = Date()
    ) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        guard let date = values?.contentModificationDate ?? values?.creationDate else {
            return true
        }
        return now.timeIntervalSince(date) < grace
    }
}

private extension Data {
    func uInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
