import Foundation
#if canImport(whisper)
import whisper
#else
#error("Unable to import whisper module. Please check your project configuration.")
#endif
import os


// Meet Whisper C++ constraint: Don't access from more than one thread at a time.
actor WhisperContext {
    private var context: OpaquePointer?
    private var prompt: String?
    private var vadModelPath: String?
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "WhisperContext")

    /// An empty context with no model; transcription on it fails. Used by tests.
    init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    /// - Parameter forceDisableVAD: When true, skip Whisper VAD even if the user setting is on.
    ///   Used to retry short/empty results that VAD may have discarded as non-speech.
    func fullTranscribe(
        samples: [Float],
        forceDisableVAD: Bool = false,
        languageCode: String
    ) -> Bool {
        guard let context = context else { return false }
        
        // P-core-bound and thermal/Low-Power-aware — see HardwareCapability.
        let maxThreads = HardwareCapability.inferenceThreadCount
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        
        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        // Greedy/deterministic first pass to reduce hallucinated repetition/gibberish (#150).
        // whisper.cpp still falls back to higher temperatures (default temperature_inc) when the
        // entropy/logprob thresholds are exceeded, so quality on hard audio is preserved.
        params.temperature = 0.0

        whisper_reset_timings(context)
        
        // Configure VAD if enabled by user and model is available
        let isVADEnabled = !forceDisableVAD && UserDefaults.standard.bool(forKey: "IsVADEnabled")
        let vadModelPath = isVADEnabled ? self.vadModelPath : nil
        if vadModelPath != nil {
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.50
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        }
        params.vad = vadModelPath != nil

        // whisper_full reads the language, prompt and VAD model path through these pointers, so
        // they must stay valid for the whole call: each one is only valid inside its closure.
        let language = languageCode != LanguagePreference.autoCode ? languageCode : nil
        let success = Self.withOptionalCString(language) { languagePointer in
            Self.withOptionalCString(prompt) { promptPointer in
                Self.withOptionalCString(vadModelPath) { vadModelPointer in
                    params.language = languagePointer
                    params.initial_prompt = promptPointer
                    params.vad_model_path = vadModelPointer
                    return samples.withUnsafeBufferPointer { samplesBuffer in
                        whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) == 0
                    }
                }
            }
        }
        if !success {
            logger.error("❌ Failed to run whisper_full. VAD enabled: \(params.vad, privacy: .public)")
        }
        return success
    }

    private static func withOptionalCString<Result>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let string else { return body(nil) }
        return string.withCString(body)
    }

    /// whisper.cpp's probability for every language it knows, from the first 30 s of `samples`.
    func languageProbabilities(samples: [Float]) -> [String: Float]? {
        guard let context, !samples.isEmpty else { return nil }
        let threads = Int32(HardwareCapability.inferenceThreadCount)
        let melStatus = samples.withUnsafeBufferPointer { buffer in
            whisper_pcm_to_mel(context, buffer.baseAddress, Int32(buffer.count), threads)
        }
        guard melStatus == 0 else { return nil }
        var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard whisper_lang_auto_detect(context, 0, threads, &probabilities) >= 0 else { return nil }
        var byCode: [String: Float] = [:]
        for (id, probability) in probabilities.enumerated() {
            if let code = whisper_lang_str(Int32(id)) {
                byCode[String(cString: code)] = probability
            }
        }
        return byCode
    }

    func transcriptionCandidate() -> WhisperLanguageCandidateSelector.Candidate {
        guard let context else {
            return .init(text: "", languageCode: nil, averageTokenProbability: 0)
        }

        var text = ""
        var probabilityTotal: Float = 0
        var probabilityCount: Float = 0
        let segmentCount = whisper_full_n_segments(context)
        for segment in 0..<segmentCount {
            text += String(cString: whisper_full_get_segment_text(context, segment))
            let tokenCount = whisper_full_n_tokens(context, segment)
            for token in 0..<tokenCount {
                let tokenText = String(cString: whisper_full_get_token_text(context, segment, token))
                guard !tokenText.isEmpty, !tokenText.hasPrefix("<|") else { continue }
                probabilityTotal += whisper_full_get_token_p(context, segment, token)
                probabilityCount += 1
            }
        }

        let languageID = whisper_full_lang_id(context)
        let languageCode: String?
        if languageID >= 0, let languagePointer = whisper_lang_str(languageID) {
            languageCode = String(cString: languagePointer)
        } else {
            languageCode = nil
        }
        return .init(
            text: text,
            languageCode: languageCode,
            averageTokenProbability: probabilityCount > 0 ? probabilityTotal / probabilityCount : 0
        )
    }

    func getTranscription() -> String {
        guard let context = context else { return "" }
        var transcription = ""
        for i in 0..<whisper_full_n_segments(context) {
            transcription += String(cString: whisper_full_get_segment_text(context, i))
        }
        return transcription
    }

    static func createContext(path: String) async throws -> WhisperContext {
        HardwareCapability.configureMetalTensorPath()
        // whisper_init_from_file_with_params is a heavy C call (can take 5–30s for large
        // models). Running it on the main actor freezes the entire UI. Load the raw C
        // context on a background thread, then hand it back to the actor.
        let logger = Logger(subsystem: "com.arcusis.zerm", category: "WhisperContext")

        let cContext: OpaquePointer = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var params = whisper_context_default_params()

                #if targetEnvironment(simulator)
                params.use_gpu = false
                if let ctx = whisper_init_from_file_with_params(path, params) {
                    continuation.resume(returning: ctx)
                    return
                }
                #else
                // Try with flash attention first (better Metal throughput for fp16/fp32).
                // Falls back without it for quantized models (q5_0, q8_0) which are
                // incompatible with the flash attention Metal kernels.
                params.flash_attn = true
                logger.info("Loading model with flash attention: \(path, privacy: .public)")
                if let ctx = whisper_init_from_file_with_params(path, params) {
                    logger.info("Model loaded with flash attention")
                    continuation.resume(returning: ctx)
                    return
                }

                logger.warning("Flash attention failed — retrying without flash attention")
                params.flash_attn = false
                if let ctx = whisper_init_from_file_with_params(path, params) {
                    logger.info("Model loaded without flash attention (quantized path)")
                    continuation.resume(returning: ctx)
                    return
                }
                #endif

                logger.error("❌ whisper_init_from_file_with_params returned nil for: \(path, privacy: .public)")
                continuation.resume(throwing: ZermEngineError.modelLoadFailed)
            }
        }

        let whisperContext = WhisperContext(context: cContext)

        // VAD model path lookup can happen on the actor
        let vadModelPath = await VADModelManager.shared.getModelPath()
        await whisperContext.setVADModelPath(vadModelPath)

        return whisperContext
    }
    
    private func setVADModelPath(_ path: String?) {
        self.vadModelPath = path
        if path != nil {
            logger.info("VAD model loaded from bundle resources")
        }
    }

    func releaseResources() {
        if let context = context {
            whisper_free(context)
            self.context = nil
        }
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }
}
