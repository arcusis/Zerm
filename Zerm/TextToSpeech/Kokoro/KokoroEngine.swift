import Foundation

/// Thread-safe wrapper around sherpa-onnx's offline Kokoro TTS. Mirrors how `WhisperContext`
/// isolates the (non-thread-safe) whisper.cpp C API in an actor.
///
/// The model (~330 MB) is loaded lazily on the actor's executor the first time `generate`
/// is called, so the heavy load never blocks the main thread.
actor KokoroEngine {
    private let modelPath: String
    private let voicesPath: String
    private let tokensPath: String
    private let dataDir: String
    private var tts: SherpaOnnxOfflineTtsWrapper?

    init(model: String, voices: String, tokens: String, dataDir: String) {
        self.modelPath = model
        self.voicesPath = voices
        self.tokensPath = tokens
        self.dataDir = dataDir
    }

    private func ensureLoaded() throws {
        guard tts == nil else { return }
        let kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: modelPath, voices: voicesPath, tokens: tokensPath, dataDir: dataDir
        )
        // Two intra-op threads left most of the machine idle during synthesis, and Kokoro sits
        // directly on the hotkey → first-spoken-word path. Scale with the box, leaving a couple
        // of cores for the UI and any concurrent dictation work.
        let threads = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: threads, provider: "cpu")
        var config = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard wrapper.tts != nil else {
            throw TTSError.notAvailable(String(localized: "Failed to initialize the on-device Kokoro engine."))
        }
        tts = wrapper
    }

    /// Loads the model ahead of time so the first `generate` is instant.
    ///
    /// Constructing the ORT session is not enough: onnxruntime allocates its activation arena
    /// on the first `Run`, espeak-ng opens its dictionary files on the first phonemize, and the
    /// model pages fault in on first touch. Without a throwaway inference the first real read
    /// still paid all of that. This runs on the actor's executor, off the main thread.
    func warmUp() throws {
        // Constructing the ORT session reads onnxruntime's global OpSchema registry, which is a
        // C++ static. If the process calls exit() while this is in flight, __cxa_finalize_ranges
        // destroys that registry underneath us and the load segfaults. Nothing here is
        // cancellable once inside sherpa-onnx, so the only safe move is not to start.
        guard !ProcessLifecycle.isTerminating else { return }
        try ensureLoaded()
        guard !ProcessLifecycle.isTerminating else { return }
        _ = tts?.generate(text: "ok", sid: 0, speed: 1.0)
    }

    func generateAudio(text: String, sid: Int, speed: Float) throws -> TTSAudio {
        try ensureLoaded()
        guard let tts else {
            throw TTSError.notAvailable(String(localized: "Kokoro engine unavailable."))
        }
        let audio = tts.generate(text: text, sid: sid, speed: speed)
        guard !audio.samples.isEmpty else { throw TTSError.emptyAudio }
        return TTSAudio(
            pcm: Self.floatToInt16PCM(audio.samples),
            sampleRate: Double(audio.sampleRate),
            channels: 1
        )
    }

    /// Runs on the Kokoro actor, not MainActor. A normal sentence contains hundreds of thousands
    /// of samples; converting them on MainActor was the visible UI freeze users described.
    private static func floatToInt16PCM(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}
