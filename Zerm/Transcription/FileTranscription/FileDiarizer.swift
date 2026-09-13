import Foundation
import FluidAudio

/// Works out who spoke when in a complete audio file.
///
/// Uses FluidAudio's LS-EEND diarizer (Apache 2.0), already a Zerm dependency for Parakeet
/// transcription. The model downloads on first use, so the first call can take a while.
/// Each call loads the model, processes the whole file and releases the model again.
enum FileDiarizer {
    /// Returns finalized speaker turns for a 16 kHz mono file (see `AudioFileConverter`).
    static func diarize(_ url: URL) async throws -> [SpeakerTurn] {
        let runtime = FileDiarizerRuntime(LSEENDDiarizer())
        try await runtime.initialize()
        defer { runtime.cleanup() }
        return try await withCheckedThrowingContinuation { continuation in
            // `processComplete` is synchronous and long-running; keep it off the cooperative pool.
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try runtime.processComplete(url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// FluidAudio does not declare its runtime Sendable. Each instance has one owner and is never
/// accessed concurrently: initialization, processing and cleanup run strictly in sequence.
private final class FileDiarizerRuntime: @unchecked Sendable {
    private let diarizer: LSEENDDiarizer

    init(_ diarizer: LSEENDDiarizer) {
        self.diarizer = diarizer
    }

    func initialize() async throws {
        try await diarizer.initialize(variant: .dihard3)
    }

    func processComplete(_ url: URL) throws -> [SpeakerTurn] {
        let timeline = try diarizer.processComplete(
            audioFileURL: url,
            keepingEnrolledSpeakers: false,
            finalizeOnCompletion: true,
            progressCallback: nil
        )
        return timeline.speakers.values.flatMap(\.finalizedSegments).map {
            SpeakerTurn(
                speakerIndex: $0.speakerIndex,
                start: TimeInterval($0.startTime),
                end: TimeInterval($0.endTime)
            )
        }
    }

    func cleanup() {
        diarizer.cleanup()
    }
}
