import Foundation

#if canImport(Speech)
import Speech
#endif

/// Languages Apple Speech offers beyond its catalog list, discovered at runtime. Apple adds
/// locales with OS updates, so Hebrew is never claimed until `SpeechTranscriber` reports it.
enum AppleSpeechLanguageSupport {
    nonisolated(unsafe) private(set) static var supportsHebrew = false

    /// Queries `SpeechTranscriber.supportedLocales` and caches whether Hebrew is among them.
    @discardableResult
    static func refresh() async -> Bool {
        guard #available(macOS 26, *) else { return false }
        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
        let locales = await SpeechTranscriber.supportedLocales
        supportsHebrew = locales.contains { $0.language.languageCode?.identifier == "he" }
        #endif
        return supportsHebrew
    }
}
