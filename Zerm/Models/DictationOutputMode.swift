import Foundation

/// How a finished transcript reaches the cursor.
///
/// This replaces the hidden `InstantTranscriptionMode` boolean, which had no UI anywhere
/// yet silently forced AI enhancement off at every launch, in the pipeline, and again on
/// every Power Mode switch — so the enhancement toggle could read ON while enhancement
/// never ran. The three cases make that trade-off explicit instead.
enum DictationOutputMode: String, Codable, CaseIterable, Identifiable {
    /// Paste the raw transcript immediately. No LLM is involved at any point.
    case instant

    /// Paste the raw transcript immediately, then replace it in place once the
    /// enhancement returns — but only through a direct accessibility write.
    /// The paste path is byte-for-byte the `instant` path; the enhancement runs
    /// afterwards on the in-memory string and never blocks it, copies it, or
    /// pastes a second time.
    case instantRefine

    /// Wait for the enhancement, then paste once. Slowest, but the pasted text is
    /// final the moment it appears.
    case enhanced

    static let storageKey = "DictationOutputMode"

    /// The AI mode that turning enhancement back on returns to.
    static let lastEnhancingModeKey = "LastEnhancingDictationOutputMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instant: return String(localized: "Instant")
        case .instantRefine: return String(localized: "Instant + Refine")
        case .enhanced: return String(localized: "Enhanced")
        }
    }

    var subtitle: String {
        switch self {
        case .instant:
            return String(localized: "Paste immediately. No AI.")
        case .instantRefine:
            return String(localized: "Paste immediately, then improve the text in place when the app allows a direct edit. Otherwise the raw text stays and the refinement is kept in History.")
        case .enhanced:
            return String(localized: "Wait for the AI, then paste once.")
        }
    }

    /// Whether the raw transcript is pasted the moment transcription finishes.
    var pastesImmediately: Bool { self != .enhanced }

    /// Whether the enhancement runs at all.
    var usesEnhancement: Bool { self != .instant }

    /// Resolves features that cannot coexist safely before the pipeline commits to a paste mode.
    /// Auto-send submits the field about half a second after paste, so a later rewrite has
    /// nothing to land on — that case waits and pastes the enhanced text once. Opaque editors
    /// no longer degrade to a wait: Instant + Refine always pastes raw immediately and treats
    /// in-place replacement as best-effort.
    static func effective(
        configured: DictationOutputMode,
        autoSendEnabled: Bool
    ) -> DictationOutputMode {
        guard configured == .instantRefine else { return configured }
        return autoSendEnabled ? .enhanced : .instantRefine
    }

    static var current: DictationOutputMode {
        current(in: .standard)
    }

    static func current(in defaults: UserDefaults) -> DictationOutputMode {
        DictationOutputMode(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .instant
    }

    static func setCurrent(_ mode: DictationOutputMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: storageKey)
        if mode.usesEnhancement {
            defaults.set(mode.rawValue, forKey: lastEnhancingModeKey)
        }
    }

    static func lastEnhancing(in defaults: UserDefaults = .standard) -> DictationOutputMode {
        guard let mode = DictationOutputMode(rawValue: defaults.string(forKey: lastEnhancingModeKey) ?? ""),
              mode.usesEnhancement else {
            return .instantRefine
        }
        return mode
    }

    /// Folds the separate "Enhancement" on/off switch into the output mode, which is now the only
    /// thing that decides whether enhancement runs.
    ///
    /// The switch and the mode could disagree — a mode that enhances with the switch off, which is
    /// how enhancement looked broken while its settings read ON. What each install did is kept: a
    /// mode that enhances with the switch off becomes Instant, and the mode it had is remembered so
    /// switching enhancement back on returns to it. Reads the registered-default fallbacks the old
    /// keys had. Removes `isAIEnhancementEnabled` and the `InstantTranscriptionMode` mirror.
    ///
    /// Untouched defaults — Instant + Refine on the On-Device provider with no enhancement model
    /// downloaded — silently behaved as Instant in 2.8.5. Those installs become Instant, so they
    /// see no new "model missing" warnings, and turning enhancement on returns to Instant + Refine.
    static func migrateLegacyEnhancementToggle(in defaults: UserDefaults, onDeviceEnhancementInstalled: Bool) {
        let enabled = defaults.object(forKey: "isAIEnhancementEnabled") as? Bool ?? true
        let mode = DictationOutputMode(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .instantRefine
        if mode.usesEnhancement {
            defaults.set(mode.rawValue, forKey: lastEnhancingModeKey)
        }
        let provider = defaults.string(forKey: "selectedAIProvider") ?? AIProvider.localLLM.rawValue
        let silentlyInstant = mode == .instantRefine
            && provider == AIProvider.localLLM.rawValue
            && !onDeviceEnhancementInstalled
        defaults.set((enabled && !silentlyInstant ? mode : .instant).rawValue, forKey: storageKey)
        defaults.removeObject(forKey: "isAIEnhancementEnabled")
        defaults.removeObject(forKey: "InstantTranscriptionMode")
    }
}
