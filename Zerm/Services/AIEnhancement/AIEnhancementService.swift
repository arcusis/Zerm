import Foundation
import SwiftData
import AppKit
import os

/// The decisions a dictation makes about enhancement once its text is known.
struct EnhancementPlan: Equatable {
    /// The mode after trigger words and auto-send are taken into account.
    let outputMode: DictationOutputMode
    /// What the LLM receives: the cleaned transcript, minus a trigger word.
    let input: String
    let overrides: EnhancementOverrides
    /// True when the "Skip short transcriptions" setting applies to this text.
    let skipsAsShort: Bool
}

/// Owns the global enhancement settings and turns them into frozen `EnhancementRequest`s.
///
/// It keeps no per-request state: a request is built once, then run by `EnhancementExecutor`,
/// so overlapping dictations, a refine that outlives its recorder, or a Power Mode switch can
/// never change or clobber another request.
@MainActor
class AIEnhancementService: ObservableObject {
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "AIEnhancementService")

    /// The only switch that decides whether dictation is enhanced.
    @Published var outputMode: DictationOutputMode {
        didSet {
            guard outputMode != oldValue else { return }
            DictationOutputMode.setCurrent(outputMode)
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            NotificationCenter.default.post(name: .enhancementToggleChanged, object: nil)
        }
    }

    /// Derived from `outputMode`, for the on/off controls. Turning it on returns to the last AI
    /// mode the user picked.
    var isEnhancementEnabled: Bool {
        get { outputMode.usesEnhancement }
        set { outputMode = newValue ? DictationOutputMode.lastEnhancing() : .instant }
    }

    @Published var useClipboardContext: Bool {
        didSet {
            UserDefaults.standard.set(useClipboardContext, forKey: "useClipboardContext")
        }
    }

    /// On-screen text as context. Only Enhanced mode uses it: a capture plus OCR does not fit
    /// the refine budget.
    @Published var useScreenCaptureContext: Bool {
        didSet {
            UserDefaults.standard.set(useScreenCaptureContext, forKey: "useScreenCaptureContext")
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }

    @Published var customPrompts: [CustomPrompt] {
        didSet {
            if let encoded = try? JSONEncoder().encode(customPrompts) {
                UserDefaults.standard.set(encoded, forKey: "customPrompts")
            }
        }
    }

    @Published var selectedPromptId: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPromptId?.uuidString, forKey: "selectedPromptId")
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            NotificationCenter.default.post(name: .promptSelectionChanged, object: nil)
        }
    }

    var activePrompt: CustomPrompt? {
        allPrompts.first { $0.id == selectedPromptId }
    }

    var allPrompts: [CustomPrompt] {
        return customPrompts
    }

    private let aiService: AIService
    private let customVocabularyService: CustomVocabularyService
    private let modelContext: ModelContext
    private let executor: EnhancementExecutor

    init(
        aiService: AIService = AIService(),
        modelContext: ModelContext,
        client: EnhancementClient = LiveEnhancementClient()
    ) {
        self.aiService = aiService
        self.modelContext = modelContext
        self.customVocabularyService = CustomVocabularyService.shared
        self.executor = EnhancementExecutor(client: client)

        self.outputMode = DictationOutputMode.current
        self.useClipboardContext = UserDefaults.standard.bool(forKey: "useClipboardContext")
        self.useScreenCaptureContext = UserDefaults.standard.bool(forKey: "useScreenCaptureContext")
        if let savedPromptsData = UserDefaults.standard.data(forKey: "customPrompts"),
           let decodedPrompts = try? JSONDecoder().decode([CustomPrompt].self, from: savedPromptsData) {
            self.customPrompts = decodedPrompts
        } else {
            self.customPrompts = []
        }

        if let savedPromptId = UserDefaults.standard.string(forKey: "selectedPromptId") {
            self.selectedPromptId = UUID(uuidString: savedPromptId)
        }

        initializePredefinedPrompts()

        if selectedPromptId == nil || !allPrompts.contains(where: { $0.id == selectedPromptId }) {
            self.selectedPromptId = allPrompts.first?.id
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAPIKeyChange),
            name: .aiProviderKeyChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Views that show `isConfigured` refresh. A removed key never switches enhancement off: the
    /// next dictation reports that the provider needs a key instead.
    @objc private func handleAPIKeyChange() {
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    func getAIService() -> AIService? {
        return aiService
    }

    /// Whether the globally selected provider can enhance right now.
    var isConfigured: Bool {
        if case .success = aiService.endpoint(for: aiService.selectedProvider, model: aiService.currentModel) {
            return true
        }
        return false
    }

    // MARK: - Requests

    func settingsSnapshot() -> EnhancementSettingsSnapshot {
        let stored = UserDefaults.standard.integer(forKey: "EnhancementTimeoutSeconds")
        return EnhancementSettingsSnapshot(
            prompts: allPrompts,
            selectedPromptID: selectedPromptId,
            provider: aiService.selectedProvider,
            modelForProvider: aiService.model(for:),
            endpointForProvider: aiService.endpoint(for:model:),
            customVocabulary: customVocabularyService.getCustomVocabulary(from: modelContext),
            timeoutSeconds: stored > 0 ? TimeInterval(stored) : EnhancementRequestBuilder.defaultTimeoutSeconds,
            retriesOnTimeout: UserDefaults.standard.bool(forKey: "EnhancementRetryOnTimeout")
        )
    }

    /// Builds the one request an enhancement will send. Everything it needs is read here.
    func makeRequest(
        input: String,
        purpose: EnhancementPurpose,
        overrides: EnhancementOverrides = EnhancementOverrides(),
        clipboardContext: String? = nil,
        screenContext: String? = nil
    ) -> Result<EnhancementRequest, EnhancementUnavailableReason> {
        EnhancementRequestBuilder.make(
            input: input,
            purpose: purpose,
            overrides: overrides,
            settings: settingsSnapshot(),
            clipboardContext: clipboardContext,
            screenContext: screenContext
        )
    }

    func perform(
        _ request: EnhancementRequest,
        isCancelled: @escaping @MainActor @Sendable () -> Bool = { false }
    ) async -> EnhancementOutcome {
        await executor.run(request, isCancelled: isCancelled)
    }

    /// Resolves trigger words, auto-send and the short-transcription setting for one dictation.
    func plan(
        for cleanedText: String,
        configuredMode: DictationOutputMode,
        autoSendEnabled: Bool,
        overrides: EnhancementOverrides
    ) -> EnhancementPlan {
        var mode = configuredMode
        var input = cleanedText
        var overrides = overrides
        var triggered = false
        if UserDefaults.standard.bool(forKey: "AllowPromptTriggeredEnhancement"),
           let detection = PromptDetectionService.detect(in: cleanedText, prompts: allPrompts) {
            triggered = true
            input = detection.processedText
            overrides.promptID = detection.promptID
            // A spoken trigger asks for AI on this dictation even when output is Instant, and
            // waits for it: there is no raw paste to refine that would not contain the trigger.
            if mode == .instant {
                mode = .enhanced
            }
        }

        let threshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
        let skipsAsShort = !triggered
            && UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
            && WordCounter.count(in: input) <= (threshold > 0 ? threshold : 3)

        return EnhancementPlan(
            outputMode: DictationOutputMode.effective(configured: mode, autoSendEnabled: autoSendEnabled),
            input: input,
            overrides: overrides,
            skipsAsShort: skipsAsShort
        )
    }

    /// History's "Re-enhance": the same request, filter and guard as dictation. The record is
    /// only changed when a new enhancement succeeds, so a failed retry keeps the existing one.
    func reenhance(_ transcription: Transcription) async -> EnhancementOutcome {
        switch makeRequest(input: transcription.text, purpose: .manual) {
        case .failure(let reason):
            return .skipped(.notConfigured(reason))
        case .success(let request):
            let outcome = await perform(request)
            if case .enhanced = outcome {
                transcription.record(outcome, of: request, finalize: TextCleanupPreferences.global().applyPreferences(to:))
                try? modelContext.save()
            }
            return outcome
        }
    }

    /// The provider a dictation with these overrides would use, for deciding what to prewarm.
    func resolvedProvider(for overrides: EnhancementOverrides) -> AIProvider {
        guard let prompt = EnhancementRequestBuilder.resolvePrompt(overrides.promptID ?? selectedPromptId, in: allPrompts) else {
            return aiService.selectedProvider
        }
        return EnhancementRequestBuilder.resolveProviderAndModel(
            overrides: overrides,
            prompt: prompt,
            globalProvider: aiService.selectedProvider,
            modelForProvider: aiService.model(for:)
        ).0
    }

    /// Text visible in the frontmost window, or nil without Screen Recording permission.
    static func captureScreenText() async -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        return await ScreenCaptureService().captureAndExtractText()
    }

    static func tokenBudget(forInput text: String) -> Int {
        EnhancementRequestBuilder.tokenBudget(forInput: text)
    }

    // MARK: - Prompts

    func addPrompt(
        title: String,
        promptText: String,
        icon: PromptIcon = "doc.text.fill",
        description: String? = nil,
        triggerWords: [String] = [],
        useSystemInstructions: Bool = true,
        providerOverride: String? = nil,
        modelOverride: String? = nil,
        allowsLanguageChange: Bool = false
    ) {
        let newPrompt = CustomPrompt(
            title: title,
            promptText: promptText,
            icon: icon,
            description: description,
            isPredefined: false,
            triggerWords: triggerWords,
            useSystemInstructions: useSystemInstructions,
            providerOverride: providerOverride,
            modelOverride: modelOverride,
            allowsLanguageChange: allowsLanguageChange
        )
        customPrompts.append(newPrompt)
        if customPrompts.count == 1 {
            selectedPromptId = newPrompt.id
        }
    }

    func updatePrompt(_ prompt: CustomPrompt) {
        if let index = customPrompts.firstIndex(where: { $0.id == prompt.id }) {
            customPrompts[index] = prompt
        }
    }

    func deletePrompt(_ prompt: CustomPrompt) {
        customPrompts.removeAll { $0.id == prompt.id }
        if selectedPromptId == prompt.id {
            selectedPromptId = allPrompts.first?.id
        }
    }

    func setActivePrompt(_ prompt: CustomPrompt) {
        selectedPromptId = prompt.id
    }

    private func initializePredefinedPrompts() {
        let predefinedTemplates = PredefinedPrompts.createDefaultPrompts()

        for template in predefinedTemplates {
            if let existingIndex = customPrompts.firstIndex(where: { $0.id == template.id }) {
                let existing = customPrompts[existingIndex]
                // The text comes from the app; the user's trigger words and model choice stay.
                customPrompts[existingIndex] = CustomPrompt(
                    id: existing.id,
                    title: template.title,
                    promptText: template.promptText,
                    icon: template.icon,
                    description: template.description,
                    isPredefined: true,
                    triggerWords: existing.triggerWords,
                    useSystemInstructions: template.useSystemInstructions,
                    providerOverride: existing.providerOverride,
                    modelOverride: existing.modelOverride,
                    allowsLanguageChange: template.allowsLanguageChange
                )
            } else {
                customPrompts.append(template)
            }
        }
    }
}
