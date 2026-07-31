import Foundation
import FluidAudio
import OSLog

/// Works out who is speaking, while the meeting is still running.
///
/// Uses FluidAudio's LS-EEND streaming diarizer (Apache 2.0), which is already a Zerm
/// dependency for Parakeet transcription, so this costs no new third-party code. Inference runs
/// on the Neural Engine, which is what makes it affordable to keep going for hours next to a
/// transcription model.
///
/// This is deliberately fed the **microphone track only**. The system track is by definition the
/// remote participants and the microphone is by definition the local room, so the two sides are
/// already separated by capture; diarizing the mic tells us how many people are in the room and
/// which of them is talking. Mixing both first would throw that free separation away and ask the
/// model to recover it.
final class MeetingDiarizer: @unchecked Sendable {

    /// A stretch of speech attributed to one voice.
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let speakerIndex: Int
        let start: TimeInterval
        let end: TimeInterval
        let isFinal: Bool

        var label: String { "Speaker \(speakerIndex + 1)" }
    }

    /// Everything upstream — the tap writer, the transcriber, the mic — is 16 kHz.
    private static let inputSampleRate: Double = 16_000

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingDiarizer")
    private let queue = DispatchQueue(label: "com.arcusis.zerm.meeting-diarizer", qos: .utility)

    private var diarizer: LSEENDDiarizer?
    /// Guarded by `stateLock`, not by `queue`.
    ///
    /// These flags were originally read and written through `queue.sync`. That is unsafe from
    /// Swift concurrency: `prepare()` is a nonisolated async function running on the cooperative
    /// pool, and blocking a pool thread on a serial queue that is also servicing `append()` can
    /// leave the write to `isReady` unperformed while `prepare()` still returns normally — which
    /// is exactly what happened, leaving the diarizer permanently neither ready nor failed. A
    /// plain lock has none of that interaction with the concurrency runtime.
    private let stateLock = NSLock()
    private var isReady = false
    private var failed = false
    /// Monotonic: once the model has been asked to load this never goes back to false.
    ///
    /// `isReady` legitimately returns to false when `finish()` tears the session down, so it
    /// cannot answer "was a model ever loaded" — asking it that gave a confidently wrong answer
    /// after any completed meeting.
    private var everLoaded = false

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Fires on the main actor whenever the picture of who-spoke-when changes.
    var onTurns: (([Turn]) -> Void)?

    private var finalized: [Turn] = []

    /// Whether the model loaded. False means speaker labels will never appear, which the caller
    /// needs to be able to tell apart from "loaded fine but nobody has spoken yet".
    var isAvailable: Bool { withState { isReady && !failed } }

    /// True once the model has been asked to load, successfully or not. Survives `finish()`.
    var didAttemptLoad: Bool { withState { everLoaded || failed } }

    // MARK: - Lifecycle

    /// Loads the model. Downloads it on first use, so this can take a while — the caller should
    /// not block recording on it.
    func prepare() async {
        do {
            let diarizer = LSEENDDiarizer()
            try await diarizer.initialize(variant: .dihard3)
            withState {
                self.diarizer = diarizer
                self.isReady = true
                self.everLoaded = true
            }
            logger.notice("Diarizer ready")
        } catch {
            withState { self.failed = true }
            // Diarization is an enhancement: a meeting still records and transcribes without it.
            logger.error("Diarizer unavailable, continuing without speaker labels: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finish() {
        queue.sync {
            guard self.withState({ self.isReady }), let diarizer else { return }
            do {
                _ = try diarizer.finalizeSession()
                publish(from: diarizer, update: nil)
            } catch {
                logger.error("Diarizer finalize failed: \(error.localizedDescription, privacy: .public)")
            }
            diarizer.cleanup()
            self.diarizer = nil
            self.withState { self.isReady = false }
        }
    }

    // MARK: - Ingest

    /// Takes the same 16 kHz mono Int16 chunks the transcriber gets.
    func append(_ data: Data) {
        queue.async { [weak self] in
            guard let self,
                  self.withState({ self.isReady && !self.failed }),
                  let diarizer = self.diarizer else { return }

            let samples = Self.floatSamples(from: data)
            guard !samples.isEmpty else { return }

            do {
                // The model runs at 8 kHz while everything else in Zerm is 16 kHz. The bare
                // addAudio(_:) means "already at the model rate", so feeding it 16 kHz audio
                // silently mis-scaled every sample: turns were still produced, but two clearly
                // different voices were decoded as one speaker. The rate has to be declared so
                // the library resamples.
                try diarizer.addAudio(samples, sourceSampleRate: Self.inputSampleRate)
                if let update = try diarizer.process() {
                    self.publish(from: diarizer, update: update)
                }
            } catch {
                self.logger.error("Diarization pass failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Publishing

    private func publish(from diarizer: LSEENDDiarizer, update: DiarizerTimelineUpdate?) {
        if let update {
            // Finalized turns never change again, so they accumulate. Tentative ones are the
            // model's current best guess about the last few seconds and are replaced wholesale
            // on every pass — appending them would make speakers flicker in and out.
            finalized.append(contentsOf: update.finalizedSegments.map { Self.turn(from: $0, isFinal: true) })
            let tentative = update.tentativeSegments.map { Self.turn(from: $0, isFinal: false) }
            let snapshot = finalized + tentative
            DispatchQueue.main.async { [weak self] in
                self?.onTurns?(snapshot)
            }
        } else {
            let snapshot = finalized
            DispatchQueue.main.async { [weak self] in
                self?.onTurns?(snapshot)
            }
        }
    }

    private static func turn(from segment: DiarizerSegment, isFinal: Bool) -> Turn {
        Turn(
            speakerIndex: segment.speakerIndex,
            start: TimeInterval(segment.startTime),
            end: TimeInterval(segment.endTime),
            isFinal: isFinal
        )
    }

    private static func floatSamples(from data: Data) -> [Float] {
        data.withUnsafeBytes { raw -> [Float] in
            let ints = raw.bindMemory(to: Int16.self)
            var out = [Float]()
            out.reserveCapacity(ints.count)
            for sample in ints {
                out.append(Float(sample) / Float(Int16.max))
            }
            return out
        }
    }
}
