import Foundation

/// How a finished transcript reaches the cursor.
///
/// This replaces the hidden `InstantTranscriptionMode` boolean, which had no UI anywhere
/// yet silently forced AI enhancement off at every launch, in the pipeline, and again on
/// every Power Mode switch — so the enhancement toggle could read ON while enhancement
/// never ran. The three cases make that trade-off explicit instead.
enum DictationOutputMode: String, CaseIterable, Identifiable {
    /// Paste the raw transcript immediately. No LLM is involved at any point.
    case instant

    /// Paste the raw transcript immediately, then replace it in place once the
    /// enhancement returns. The paste path is byte-for-byte the `instant` path;
    /// the enhancement runs afterwards and never blocks it.
    case instantRefine

    /// Wait for the enhancement, then paste once. Slowest, but the pasted text is
    /// final the moment it appears.
    case enhanced

    static let storageKey = "DictationOutputMode"

    /// The pre-`DictationOutputMode` flag. Still written as a derived mirror so that any
    /// path not yet migrated keeps behaving the same; remove once nothing reads it.
    static let legacyInstantKey = "InstantTranscriptionMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instant: return "Instant"
        case .instantRefine: return "Instant + Refine"
        case .enhanced: return "Enhanced"
        }
    }

    var subtitle: String {
        switch self {
        case .instant:
            return "Paste immediately. No AI."
        case .instantRefine:
            return "Paste immediately, then improve the text in place. Works in apps that support macOS text accessibility; elsewhere the refined version is offered without changing what you typed."
        case .enhanced:
            return "Wait for the AI, then paste once."
        }
    }

    /// Whether the raw transcript is pasted the moment transcription finishes.
    var pastesImmediately: Bool { self != .enhanced }

    /// Whether the enhancement runs at all.
    var usesEnhancement: Bool { self != .instant }

    static var current: DictationOutputMode {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return DictationOutputMode(rawValue: raw) ?? .instant
    }

    static func setCurrent(_ mode: DictationOutputMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
        UserDefaults.standard.set(mode != .enhanced, forKey: legacyInstantKey)
    }
}
