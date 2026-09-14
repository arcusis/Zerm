import FluidAudio
import Foundation
import os

/// On-device streaming using FluidAudio ASR. Agreement-based passes drive the live preview; the
/// committed transcript is one pass over the whole recording, identical to batch transcription.
final class FluidAudioStreamingProvider: StreamingTranscriptionProvider {

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "FluidAudioStreaming")
    private let fluidAudioService: FluidAudioTranscriptionService
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    let finishesEventsOnCommit = true

    // The whole recording: the final pass needs all of it, previews slice from the seek point.
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private let sampleRate: Double = 16000.0

    private var model: (any TranscriptionModel)?
    private var asrManager: AsrManager?
    private var decoderLayerCount: Int = 0
    private let agreementEngine: WordAgreementEngine
    private let config: AgreementConfig

    private var transcriptionTask: Task<Void, Never>?
    private var isTranscribing = false
    private var lastTranscribedSampleCount = 0
    private let minNewSamples = 8000 // ~0.5s

    private func withBufferLock<T>(_ body: () throws -> T) rethrows -> T {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return try body()
    }

    init(fluidAudioService: FluidAudioTranscriptionService, config: AgreementConfig = AgreementConfig()) {
        self.fluidAudioService = fluidAudioService
        self.config = config
        self.agreementEngine = WordAgreementEngine(config: config)

        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        transcriptionTask?.cancel()
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        let version: AsrModelVersion = FluidAudioModelManager.asrVersion(for: model.name)
        let models = try await TranscriptionInferenceScheduler.shared.run(
            provider: .fluidAudio,
            priority: .dictation
        ) {
            try await self.fluidAudioService.getOrLoadModels(for: version)
        }

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.decoderLayerCount = await manager.decoderLayerCount
        self.model = model

        agreementEngine.reset()
        withBufferLock { audioBuffer = [] }
        lastTranscribedSampleCount = 0

        startTranscriptionLoop()

        eventsContinuation?.yield(.sessionStarted)
        logger.notice("FluidAudio agreement streaming started for \(model.displayName, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        let samples = Self.convertToFloat32(data)
        withBufferLock { audioBuffer.append(contentsOf: samples) }
    }

    func commit() async throws {
        // Stop the preview loop first so no preview pass runs alongside the final pass.
        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil

        guard let model else { throw StreamingTranscriptionError.notConnected }
        let samples = withBufferLock { audioBuffer }

        // Transcribe the complete recording through the batch path rather than stitching
        // confirmed preview chunks to a remainder pass: agreement seams, a preview pass still
        // running at stop, or a short trailing remainder can then never drop the last words.
        let text = try await TranscriptionInferenceScheduler.shared.run(
            provider: .fluidAudio,
            priority: .dictation
        ) {
            try await self.fluidAudioService.transcribe(samples: samples, model: model)
        }
        eventsContinuation?.yield(.committed(text: text))
        eventsContinuation?.finish()
    }

    func disconnect() async {
        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil

        await asrManager?.cleanup()
        asrManager = nil
        decoderLayerCount = 0

        withBufferLock { audioBuffer = [] }
        model = nil
        agreementEngine.reset()

        eventsContinuation?.finish()
        logger.notice("FluidAudio agreement streaming disconnected")
    }

    // MARK: - Private

    private func startTranscriptionLoop() {
        transcriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(
                        (self?.config.transcribeIntervalSeconds ?? 1.0) * 1_000_000_000
                    ))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.runTranscriptionPass()
            }
        }
    }

    private func runTranscriptionPass() async {
        guard !isTranscribing else { return }
        guard let asrManager else { return }

        let sampleCount = withBufferLock { audioBuffer.count }

        guard sampleCount - lastTranscribedSampleCount >= minNewSamples else { return }
        guard sampleCount >= Int(sampleRate) else { return }

        isTranscribing = true
        defer { isTranscribing = false }

        // Seek to the start of the first unconfirmed word so it isn't clipped.
        let seekTime = agreementEngine.hypothesisStartTime > 0
            ? agreementEngine.hypothesisStartTime
            : agreementEngine.confirmedEndTime
        let seekSample = max(0, Int(seekTime * sampleRate))

        guard var audioSlice = withBufferLock({ () -> [Float]? in
            guard seekSample < sampleCount else { return nil }
            return Array(audioBuffer[seekSample..<sampleCount])
        }) else { return }

        // Pad with 1s trailing silence for punctuation capture
        let maxSingleChunkSamples = 240_000
        let trailingSilenceSamples = 16_000
        if audioSlice.count + trailingSilenceSamples <= maxSingleChunkSamples {
            audioSlice += [Float](repeating: 0, count: trailingSilenceSamples)
        }

        guard audioSlice.count >= Int(sampleRate) else { return }

        do {
            var state = TdtDecoderState.make(decoderLayers: decoderLayerCount)
            let result = try await asrManager.transcribe(audioSlice, decoderState: &state)
            // Commit cancelled this pass; its preview is stale and the final pass covers its audio.
            guard !Task.isCancelled else { return }
            lastTranscribedSampleCount = sampleCount

            guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    eventsContinuation?.yield(.partial(text: result.text))
                }
                return
            }

            let timeOffset = Double(seekSample) / sampleRate
            let words = WordAgreementEngine.mergeTokensToWords(tokenTimings, timeOffset: timeOffset)
            guard !words.isEmpty else { return }

            let agreementResult = agreementEngine.processTranscriptionResult(words: words, resultConfidence: result.confidence)

            // Confirmed words only stabilise the preview; the committed text comes from commit().
            if !agreementResult.fullText.isEmpty {
                eventsContinuation?.yield(.partial(text: agreementResult.fullText))
            }
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Transcription pass failed: \(error.localizedDescription, privacy: .public)")
            eventsContinuation?.yield(.error(error))
        }
    }

    // MARK: - Audio Conversion

    private static func convertToFloat32(_ data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { rawPtr in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Ptr[i]) / 32767.0
            }
        }
        return samples
    }
}
