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
        let modelConfig = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 2, provider: "cpu")
        var config = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard wrapper.tts != nil else {
            throw TTSError.notAvailable("Failed to initialize the on-device Kokoro engine.")
        }
        tts = wrapper
    }

    /// Loads the model ahead of time so the first `generate` is instant.
    func warmUp() throws {
        try ensureLoaded()
    }

    func generate(text: String, sid: Int, speed: Float) throws -> (samples: [Float], sampleRate: Int) {
        try ensureLoaded()
        guard let tts else { throw TTSError.notAvailable("Kokoro engine unavailable.") }
        let audio = tts.generate(text: text, sid: sid, speed: speed)
        return (audio.samples, Int(audio.sampleRate))
    }
}
