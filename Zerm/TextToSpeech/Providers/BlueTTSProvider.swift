import Foundation

struct BlueTTSProvider: TTSProvider {
    let kind: TTSProviderKind = .blue
    let displayName = String(localized: "Blue v2")
    let voices = [
        TTSVoice(id: "female1", displayName: String(localized: "Blue · Female"), provider: .blue, language: "en")
    ]

    func synthesize(text: String, voice: TTSVoice, speed: Double, apiKey: String) async throws -> TTSAudio {
        try await BlueModelManager.shared.synthesize(
            text: text,
            language: BlueTextFrontend.dominantLanguage(of: text),
            speed: speed
        )
    }
}
