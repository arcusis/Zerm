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
    private var languageCString: [CChar]?
    private var prompt: String?
    private var promptCString: [CChar]?
    private var vadModelPath: String?
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "WhisperContext")

    private init() {}

    init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        if let context = context {
            whisper_free(context)
        }
    }

    func fullTranscribe(samples: [Float]) -> Bool {
        guard let context = context else { return false }
        
        let maxThreads = max(1, min(8, cpuCount() - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        
        // Read language directly from UserDefaults
        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "auto"
        if selectedLanguage != "auto" {
            languageCString = Array(selectedLanguage.utf8CString)
            params.language = languageCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            languageCString = nil
            params.language = nil
        }
        
        if prompt != nil {
            promptCString = Array(prompt!.utf8CString)
            params.initial_prompt = promptCString?.withUnsafeBufferPointer { ptr in
                ptr.baseAddress
            }
        } else {
            promptCString = nil
            params.initial_prompt = nil
        }
        
        params.print_realtime = true
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.temperature = 0.2

        whisper_reset_timings(context)
        
        // Configure VAD if enabled by user and model is available
        let isVADEnabled = UserDefaults.standard.bool(forKey: "IsVADEnabled")
        if isVADEnabled, let vadModelPath = self.vadModelPath {
            params.vad = true
            params.vad_model_path = (vadModelPath as NSString).utf8String
            
            var vadParams = whisper_vad_default_params()
            vadParams.threshold = 0.50
            vadParams.min_speech_duration_ms = 250
            vadParams.min_silence_duration_ms = 100
            vadParams.max_speech_duration_s = Float.greatestFiniteMagnitude
            vadParams.speech_pad_ms = 30
            vadParams.samples_overlap = 0.1
            params.vad_params = vadParams
        } else {
            params.vad = false
        }
        
        var success = true
        samples.withUnsafeBufferPointer { samplesBuffer in
            if whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count)) != 0 {
                logger.error("❌ Failed to run whisper_full. VAD enabled: \(params.vad, privacy: .public)")
                success = false
            }
        }
        
        languageCString = nil
        promptCString = nil
        
        return success
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
        languageCString = nil
    }

    func setPrompt(_ prompt: String?) {
        self.prompt = prompt
    }
}

fileprivate func cpuCount() -> Int {
    ProcessInfo.processInfo.processorCount
}
