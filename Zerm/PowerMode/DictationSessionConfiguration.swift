import Foundation
import os

/// Waits for work that dictation may use but must never be held up by.
enum BoundedWait {
    private static let pollInterval: UInt64 = 20_000_000

    /// The task's value if it arrives within `seconds` and before `isCancelled`, otherwise nil. The
    /// task keeps running either way; `Task.value` cannot be abandoned by cancelling its awaiter, so
    /// the value and a timer race through one continuation.
    static func value<T: Sendable>(
        of task: Task<T, Never>,
        within seconds: TimeInterval,
        isCancelled: @escaping @MainActor @Sendable () -> Bool = { false }
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (T?) -> Void = { value in
                let shouldResume = resumed.withLock { alreadyResumed -> Bool in
                    defer { alreadyResumed = true }
                    return !alreadyResumed
                }
                if shouldResume { continuation.resume(returning: value) }
            }
            Task { finish(await task.value) }
            Task {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline, !(await isCancelled()), !resumed.withLock({ $0 }) {
                    try? await Task.sleep(nanoseconds: pollInterval)
                }
                finish(nil)
            }
        }
    }
}

/// The user's lowercase, punctuation and formatting choices for one dictation.
struct TextCleanupPreferences: Equatable, Sendable {
    let formatsText: Bool
    let punctuation: PunctuationCleanupMode
    let lowercases: Bool

    static func global(in defaults: UserDefaults = .standard) -> TextCleanupPreferences {
        TextCleanupPreferences(
            formatsText: defaults.bool(forKey: "IsTextFormattingEnabled"),
            punctuation: PunctuationCleanupMode.current(in: defaults),
            lowercases: defaults.bool(forKey: "LowercaseTranscription")
        )
    }

    func overridden(by config: PowerModeConfig?) -> TextCleanupPreferences {
        TextCleanupPreferences(
            formatsText: config?.isTextFormattingEnabled ?? formatsText,
            punctuation: config?.punctuationCleanupMode ?? punctuation,
            lowercases: config?.lowercaseTranscription ?? lowercases
        )
    }

    /// Applied to the text that is pasted, and again to an enhancement, so a model that restores
    /// capitals or punctuation cannot undo the user's choice.
    func applyPreferences(to text: String) -> String {
        TranscriptionOutputFilter.applyCleanupPreferences(text, punctuationMode: punctuation, shouldLowercase: lowercases)
    }
}

/// Everything one dictation runs under, resolved once when recording starts.
///
/// The transcription session, the text pipeline, History and enhancement all read this value, so
/// a Power Mode never has to write global settings and restore them afterwards, and nothing that
/// happens after recording starts — a late browser URL match, a settings change — can switch the
/// model or language of a recording already in progress.
///
/// The only way to change it mid-recording is an explicit choice in the recorder (a Power Mode,
/// prompt or output-mode shortcut), collected in `RecorderChoices` and applied at hand-off.
struct DictationSessionConfiguration {
    let powerMode: PowerModeConfig?
    let transcriptionModel: any TranscriptionModel
    let languageCode: String
    /// The global cleanup preferences when recording started, before Power Mode overrides.
    let globalTextCleanup: TextCleanupPreferences
    /// Captured at start only when clipboard context is on; never written to disk.
    let clipboardContext: String?
    /// On-screen text, captured in the background at start for Enhanced output only.
    let screenContext: Task<String?, Never>?
    let explicitOutputMode: DictationOutputMode?
    let explicitPromptID: UUID?

    private static let logger = Logger(subsystem: "com.arcusis.zerm", category: "DictationSession")

    var textCleanup: TextCleanupPreferences {
        globalTextCleanup.overridden(by: powerMode)
    }

    func configuredOutputMode(global: DictationOutputMode) -> DictationOutputMode {
        explicitOutputMode ?? powerMode?.outputMode ?? global
    }

    var autoSendEnabled: Bool {
        powerMode?.autoSendKey.isEnabled == true
    }

    var enhancementOverrides: EnhancementOverrides {
        let provider = powerMode?.selectedAIProvider
            .flatMap(AIProvider.init(rawValue:))
            .flatMap { $0.isTranscriptionOnly ? nil : $0 }
        return EnhancementOverrides(
            promptID: explicitPromptID ?? powerMode?.selectedPrompt.flatMap(UUID.init(uuidString:)),
            provider: provider,
            model: provider == nil ? nil : powerMode?.selectedAIModel
        )
    }

    func usesScreenContext(global: Bool) -> Bool {
        powerMode?.contextAwareness ?? global
    }

    /// Resolves a Power Mode against the global settings. An overridden transcription model that is
    /// no longer usable (deleted, key removed) falls back to the global model rather than failing
    /// the recording.
    static func resolve(
        powerMode: PowerModeConfig?,
        globalModel: any TranscriptionModel,
        usableModels: [any TranscriptionModel],
        globalLanguage: String,
        globalTextCleanup: TextCleanupPreferences,
        clipboardContext: String? = nil,
        screenContext: Task<String?, Never>? = nil
    ) -> DictationSessionConfiguration {
        var model = globalModel
        if let name = powerMode?.selectedTranscriptionModelName {
            if let override = usableModels.first(where: { $0.name == name }) {
                model = override
            } else {
                logger.notice("Power Mode model \(name, privacy: .public) is not usable; using the global model")
            }
        }
        return DictationSessionConfiguration(
            powerMode: powerMode,
            transcriptionModel: model,
            languageCode: powerMode?.selectedLanguage ?? globalLanguage,
            globalTextCleanup: globalTextCleanup,
            clipboardContext: clipboardContext,
            screenContext: screenContext,
            explicitOutputMode: nil,
            explicitPromptID: nil
        )
    }

    /// The recorder's choices replace the enhancement side only: the transcription model and
    /// language are already bound to the live transcription session.
    func applying(_ choices: RecorderChoices) -> DictationSessionConfiguration {
        DictationSessionConfiguration(
            powerMode: choices.powerMode ?? powerMode,
            transcriptionModel: transcriptionModel,
            languageCode: languageCode,
            globalTextCleanup: globalTextCleanup,
            clipboardContext: clipboardContext,
            screenContext: screenContext,
            explicitOutputMode: choices.outputMode ?? explicitOutputMode,
            explicitPromptID: choices.promptID ?? explicitPromptID
        )
    }
}
