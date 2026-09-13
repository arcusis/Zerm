import Foundation

/// The engine a local model runs on, which decides the Macs it can run on.
enum LocalModelRuntime {
    /// whisper.cpp: every Mac.
    case whisperCpp
    /// FluidAudio Core ML models: Apple Silicon only.
    case fluidAudio
    /// SpeechAnalyzer: Apple Silicon on macOS 26 or later.
    case appleSpeech
}

/// A catalog model that transcribes on this Mac. Carries what hardware recommendations need.
protocol LocalTranscriptionModel: TranscriptionModel {
    var runtime: LocalModelRuntime { get }
    /// Rough peak working set while transcribing.
    var estimatedRAMGB: Double { get }
    var speed: Double { get }
    var accuracy: Double { get }
}

extension WhisperModel: LocalTranscriptionModel {
    var runtime: LocalModelRuntime { .whisperCpp }
}

extension FluidAudioModel: LocalTranscriptionModel {
    var runtime: LocalModelRuntime { .fluidAudio }
}

extension NativeAppleModel: LocalTranscriptionModel {
    var runtime: LocalModelRuntime { .appleSpeech }
    /// The speech model lives in a system process; Zerm only holds the audio.
    var estimatedRAMGB: Double { 0.5 }
    var speed: Double { 0.95 }
    var accuracy: Double { 0.9 }
}
