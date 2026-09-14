import Foundation

/// Choices made in the recorder — ⌘E, a prompt, a Power Mode — while a recording runs. They
/// apply to that recording only and are never written to settings.
struct RecorderChoices: Equatable {
    var outputMode: DictationOutputMode?
    var promptID: UUID?
    var powerMode: PowerModeConfig?
}

/// Which recording is live, the configuration it resolved, and the recorder choices made during it.
///
/// Resolving a Power Mode can wait on a browser, so a recording may stop — or a new one start —
/// before its resolution returns. Every resolution is tied to the recording that asked for it and
/// is discarded if that recording is no longer the live one.
@MainActor
final class DictationSessionTracker: ObservableObject {
    enum Resolution {
        case resolved(PowerModeConfig?)
        /// The recording stopped or was replaced while resolving.
        case stale
    }

    private(set) var generation = 0
    private(set) var requestedPowerModeId: UUID?
    @Published private(set) var configuration: DictationSessionConfiguration?
    @Published private(set) var choices = RecorderChoices()

    /// A recording is starting. Returns its generation; anything left from an earlier one is dropped.
    func begin(powerModeId: UUID?) -> Int {
        generation += 1
        requestedPowerModeId = powerModeId
        configuration = nil
        choices = RecorderChoices()
        return generation
    }

    /// The recording stopped: a resolution still in flight for it is now stale.
    func stop() {
        generation += 1
    }

    func resolvePowerMode(
        for generation: Int,
        isLive: () -> Bool,
        using resolver: () async -> PowerModeConfig?
    ) async -> Resolution {
        let config = await resolver()
        guard generation == self.generation, isLive() else { return .stale }
        return .resolved(config)
    }

    /// Stores the configuration for the live recording; ignored for any other.
    @discardableResult
    func setConfiguration(_ configuration: DictationSessionConfiguration, for generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        self.configuration = configuration
        return true
    }

    /// Hands the recording's configuration, with the recorder choices applied, to the pipeline.
    /// `fallback` builds one for a recording that stopped before it resolved.
    func takeConfiguration(fallback: () -> DictationSessionConfiguration?) -> DictationSessionConfiguration? {
        let session = (configuration ?? fallback())?.applying(choices)
        end()
        return session
    }

    func end() {
        generation += 1
        configuration = nil
        choices = RecorderChoices()
    }

    // MARK: - Recorder

    private var effectivePowerMode: PowerModeConfig? {
        choices.powerMode ?? configuration?.powerMode
    }

    func effectiveOutputMode(global: DictationOutputMode) -> DictationOutputMode {
        choices.outputMode ?? effectivePowerMode?.outputMode ?? global
    }

    func effectivePromptID(global: UUID?) -> UUID? {
        choices.promptID ?? effectivePowerMode?.selectedPrompt.flatMap(UUID.init(uuidString:)) ?? global
    }

    func toggleEnhancement(global: DictationOutputMode) {
        choices.outputMode = effectiveOutputMode(global: global).usesEnhancement
            ? .instant
            : DictationOutputMode.lastEnhancing()
    }

    /// Picking a prompt asks for AI on this recording.
    func selectPrompt(_ promptID: UUID, global: DictationOutputMode) {
        choices.promptID = promptID
        if !effectiveOutputMode(global: global).usesEnhancement {
            choices.outputMode = DictationOutputMode.lastEnhancing()
        }
    }

    func selectPowerMode(_ config: PowerModeConfig) {
        choices.powerMode = config
    }
}
