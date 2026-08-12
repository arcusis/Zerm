import AVFoundation
import Foundation

/// Apple's installed macOS voices. This provider is intentionally offered but not selected by
/// default: it is the zero-account, on-device fallback and exposes Hebrew whenever the user has a
/// Hebrew system voice installed.
struct AppleSystemTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .appleSystem
    let displayName = String(localized: "Apple System Voices")

    var voices: [TTSVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .map {
                TTSVoice(
                    id: $0.identifier,
                    displayName: "\($0.name) (\(Self.languageName($0.language)))",
                    provider: .appleSystem,
                    language: $0.language
                )
            }
            .sorted {
                let lhsRank = Self.languageRank($0.language)
                let rhsRank = Self.languageRank($1.language)
                return lhsRank == rhsRank ? $0.displayName < $1.displayName : lhsRank < rhsRank
            }
    }

    var requiresAPIKey: Bool { false }

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        guard let systemVoice = AVSpeechSynthesisVoice(identifier: voice.id) else {
            throw TTSError.notAvailable(String(localized: "The selected Apple voice is no longer installed."))
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = systemVoice
        // AVSpeechUtterance's useful range is provider-defined around defaultSpeechRate. Keep the
        // app's 0.5x...2x control proportional while respecting the documented absolute bounds.
        utterance.rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed))
        )

        return try await AppleSpeechRenderSession.render(utterance)
    }

    private static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private static func languageRank(_ identifier: String) -> Int {
        let code = Locale(identifier: identifier).language.languageCode?.identifier
        let current = Locale.current.language.languageCode?.identifier
        if code == current { return 0 }
        if code == "he" { return 1 }
        if code == "en" { return 2 }
        return 3
    }
}

private final class AppleSpeechRenderSession: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TTSAudio, Error>?
    private var synthesizer: AVSpeechSynthesizer?
    private var pcm = Data()
    private var sampleRate: Double = 0
    private var channels = 0
    private var finished = false

    static func render(_ utterance: AVSpeechUtterance) async throws -> TTSAudio {
        try await withCheckedThrowingContinuation { continuation in
            let session = AppleSpeechRenderSession()
            session.continuation = continuation
            let synthesizer = AVSpeechSynthesizer()
            session.synthesizer = synthesizer
            synthesizer.write(utterance) { buffer in
                session.consume(buffer)
            }
        }
    }

    private func consume(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let buffer = buffer as? AVAudioPCMBuffer else { return }

        if buffer.frameLength == 0 {
            finished = true
            let result = TTSAudio(
                pcm: pcm,
                sampleRate: sampleRate > 0 ? sampleRate : 22_050,
                channels: max(1, channels)
            )
            let continuation = continuation
            self.continuation = nil
            synthesizer = nil
            if result.pcm.isEmpty {
                continuation?.resume(throwing: TTSError.emptyAudio)
            } else {
                continuation?.resume(returning: result)
            }
            return
        }

        sampleRate = buffer.format.sampleRate
        channels = Int(max(AVAudioChannelCount(1), buffer.format.channelCount))
        appendInt16Interleaved(buffer)
    }

    private func appendInt16Interleaved(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        if let floatData = buffer.floatChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let sampleIndex = buffer.format.isInterleaved ? frame * channels + channel : frame
                    let channelIndex = buffer.format.isInterleaved ? 0 : channel
                    let sample = max(-1, min(1, floatData[channelIndex][sampleIndex]))
                    var value = Int16(sample * Float(Int16.max)).littleEndian
                    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
                }
            }
            return
        }

        if let int16Data = buffer.int16ChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    let sampleIndex = buffer.format.isInterleaved ? frame * channels + channel : frame
                    let channelIndex = buffer.format.isInterleaved ? 0 : channel
                    var value = int16Data[channelIndex][sampleIndex].littleEndian
                    withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
                }
            }
        }
    }
}
