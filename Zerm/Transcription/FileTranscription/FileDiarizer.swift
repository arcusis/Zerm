import Foundation
import FluidAudio

/// How many voices the diarizer should look for.
enum SpeakerCount: Hashable, Codable, Sendable {
    case automatic
    case fixed(Int)

    static let fixedRange = 2...10
}

/// Works out who spoke when in a complete audio file.
///
/// Uses FluidAudio's offline diarizer (pyannote Community-1 parity, Apache 2.0). Its models
/// download into FluidAudio's shared model folder on first use, beside the Parakeet models, so
/// the first call can take a while. Each call loads the models, streams the file from disk and
/// releases the models again, so memory stays bounded for hours-long recordings.
enum FileDiarizer {
    /// Thrown when the diarization models cannot be downloaded or loaded.
    struct ModelUnavailable: Error {
        let underlying: Error
    }

    /// Returns speaker turns for a 16 kHz mono file (see `AudioFileConverter`). `onProgress`
    /// receives the fraction of the file analysed so far.
    static func diarize(
        _ url: URL,
        speakers: SpeakerCount,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> [SpeakerTurn] {
        var config = OfflineDiarizerConfig.default
        if case .fixed(let count) = speakers {
            config = config.withSpeakers(exactly: count)
        }
        let manager = OfflineDiarizerManager(config: config)
        do {
            try await manager.prepareModels()
        } catch {
            throw ModelUnavailable(underlying: error)
        }
        try Task.checkCancellation()

        do {
            let result = try await manager.process(url) { processed, total in
                Task { await onProgress(Double(processed) / Double(max(1, total))) }
            }
            return turns(from: result.segments.map {
                (speakerID: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
            })
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
    }

    /// Maps FluidAudio's string speaker ids to indices in order of first appearance.
    static func turns(from segments: [(speakerID: String, start: TimeInterval, end: TimeInterval)]) -> [SpeakerTurn] {
        var indices: [String: Int] = [:]
        return segments
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
            .map { segment in
                let index = indices[segment.speakerID] ?? indices.count
                indices[segment.speakerID] = index
                return SpeakerTurn(speakerIndex: index, start: segment.start, end: segment.end)
            }
    }
}
