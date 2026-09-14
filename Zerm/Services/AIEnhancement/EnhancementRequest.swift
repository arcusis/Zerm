import Foundation

/// What an enhancement is for. Decides its time budget.
enum EnhancementPurpose: Sendable {
    /// The paste waits for the result.
    case enhanced
    /// The raw transcript is already pasted; the result replaces it in place when it can.
    case refine
    /// Started by hand, from History.
    case manual
}

/// Whether the result must keep the writing system and rough length of its input.
enum EnhancementLanguagePolicy: Sendable, Equatable {
    /// Cleanup prompts: `EnhancementLanguageGuard` rejects a translated or runaway rewrite.
    case preserveScript
    /// Prompts meant to translate, answer or expand: the guard does not apply.
    case mayChangeLanguage
}

/// Where a request is sent, with everything needed to send it captured when it is built.
enum EnhancementEndpoint: Sendable, Equatable {
    case onDevice(packageFileName: String)
    case ollama(baseURL: String, model: String)
    case localCLI(commandTemplate: String, timeout: TimeInterval)
    case anthropic(apiKey: String, model: String)
    case openAICompatible(baseURL: String, apiKey: String, model: String)
}

/// Why no request could be built for the resolved provider.
enum EnhancementUnavailableReason: Error, Sendable, Equatable {
    case onDeviceModelMissing(modelName: String)
    case apiKeyMissing(provider: AIProvider)
    case modelMissing(provider: AIProvider)
    case endpointInvalid(provider: AIProvider)
    case commandMissing
    case transcriptionOnlyProvider(provider: AIProvider)
    case promptMissing
}

/// Optional choices that beat the global enhancement settings for one request.
struct EnhancementOverrides: Equatable, Sendable {
    var promptID: UUID?
    /// When set, `model` belongs to it; without a provider `model` is ignored.
    var provider: AIProvider?
    var model: String?
}

/// One enhancement, frozen when it is built.
///
/// Prompt, provider, model, context, timeout and language policy are all resolved into this value
/// before anything is sent. Nothing downstream reads shared settings or service state, so a
/// recording that outlives its recorder, a Power Mode switch, or a settings change mid-request
/// cannot change what this request does.
struct EnhancementRequest: Sendable {
    let purpose: EnhancementPurpose
    /// The text being enhanced, which the language guard compares the result against.
    let inputText: String
    let systemMessage: String
    let userMessage: String
    let promptID: UUID
    let promptTitle: String
    let provider: AIProvider
    let model: String
    let endpoint: EnhancementEndpoint
    let timeout: TimeInterval
    let retriesOnTimeout: Bool
    let languagePolicy: EnhancementLanguagePolicy
    let maxOutputTokens: Int
}

/// The global enhancement settings a request is built from, read once.
struct EnhancementSettingsSnapshot {
    var prompts: [CustomPrompt]
    var selectedPromptID: UUID?
    var provider: AIProvider
    var modelForProvider: (AIProvider) -> String
    var endpointForProvider: (AIProvider, String) -> Result<EnhancementEndpoint, EnhancementUnavailableReason>
    var customVocabulary: String
    var timeoutSeconds: TimeInterval
    var retriesOnTimeout: Bool
}

enum EnhancementRequestBuilder {
    /// A refine lands after the user has moved on if it is slow, and nobody is waiting on it, so
    /// its budget is fixed. Enhanced mode uses the Timeout setting.
    static let refineTimeout: TimeInterval = 8

    static let defaultTimeoutSeconds: TimeInterval = 15

    static func make(
        input: String,
        purpose: EnhancementPurpose,
        overrides: EnhancementOverrides,
        settings: EnhancementSettingsSnapshot,
        clipboardContext: String? = nil,
        screenContext: String? = nil
    ) -> Result<EnhancementRequest, EnhancementUnavailableReason> {
        guard let prompt = resolvePrompt(overrides.promptID ?? settings.selectedPromptID, in: settings.prompts) else {
            return .failure(.promptMissing)
        }
        let (provider, model) = resolveProviderAndModel(
            overrides: overrides,
            prompt: prompt,
            globalProvider: settings.provider,
            modelForProvider: settings.modelForProvider
        )
        guard !provider.isTranscriptionOnly else {
            return .failure(.transcriptionOnlyProvider(provider: provider))
        }

        let endpoint: EnhancementEndpoint
        switch settings.endpointForProvider(provider, model) {
        case .success(let resolved): endpoint = resolved
        case .failure(let reason): return .failure(reason)
        }

        var timeout = purpose == .refine ? refineTimeout : settings.timeoutSeconds
        if case .localCLI(_, let commandTimeout) = endpoint, purpose != .refine {
            // A CLI agent has its own, usually longer, timeout setting.
            timeout = max(timeout, commandTimeout)
        }
        let policy: EnhancementLanguagePolicy = prompt.allowsLanguageChange ? .mayChangeLanguage : .preserveScript

        return .success(EnhancementRequest(
            purpose: purpose,
            inputText: input,
            systemMessage: systemMessage(
                prompt: prompt,
                clipboardContext: clipboardContext,
                screenContext: screenContext,
                customVocabulary: settings.customVocabulary
            ),
            userMessage: "\n<TRANSCRIPT>\n\(input)\n</TRANSCRIPT>",
            promptID: prompt.id,
            promptTitle: prompt.title,
            provider: provider,
            model: model,
            endpoint: endpoint,
            timeout: timeout,
            retriesOnTimeout: purpose != .refine && settings.retriesOnTimeout,
            languagePolicy: policy,
            maxOutputTokens: policy == .preserveScript ? tokenBudget(forInput: input) : 512
        ))
    }

    static func resolvePrompt(_ id: UUID?, in prompts: [CustomPrompt]) -> CustomPrompt? {
        prompts.first { $0.id == id }
            ?? prompts.first { $0.id == PredefinedPrompts.defaultPromptId }
            ?? prompts.first
    }

    /// Power Mode beats the prompt, the prompt beats the global selection. A model is only ever
    /// taken together with the provider it was chosen for.
    static func resolveProviderAndModel(
        overrides: EnhancementOverrides,
        prompt: CustomPrompt,
        globalProvider: AIProvider,
        modelForProvider: (AIProvider) -> String
    ) -> (AIProvider, String) {
        if let provider = overrides.provider {
            return (provider, nonEmpty(overrides.model) ?? modelForProvider(provider))
        }
        if let provider = prompt.providerOverride.flatMap(AIProvider.init(rawValue:)), !provider.isTranscriptionOnly {
            return (provider, nonEmpty(prompt.modelOverride) ?? modelForProvider(provider))
        }
        return (globalProvider, modelForProvider(globalProvider))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// A rewrite is roughly the length of its input, so a twenty-word dictation should never be
    /// allowed to run out to a flat 512 tokens — that alone can overrun the refine budget on the
    /// on-device model.
    static func tokenBudget(forInput text: String) -> Int {
        min(512, max(64, text.utf16.count / 3))
    }

    static func systemMessage(
        prompt: CustomPrompt,
        clipboardContext: String?,
        screenContext: String?,
        customVocabulary: String
    ) -> String {
        var sections = ""
        if let clipboardContext, !clipboardContext.isEmpty {
            sections += "\n\n<CLIPBOARD_CONTEXT>\n\(clipboardContext)\n</CLIPBOARD_CONTEXT>"
        }
        if let screenContext, !screenContext.isEmpty {
            sections += "\n\n<CURRENT_WINDOW_CONTEXT>\n\(screenContext)\n</CURRENT_WINDOW_CONTEXT>"
        }
        if !customVocabulary.isEmpty {
            sections += """


            The following are important vocabulary words, proper nouns, and technical terms. When these words or similar-sounding words appear in the <TRANSCRIPT>, ensure they are spelled EXACTLY as shown below:
            <CUSTOM_VOCABULARY>
            \(customVocabulary)
            </CUSTOM_VOCABULARY>
            """
        }
        if TechnicalTerminology.isCodingPrompt(prompt.id) {
            sections += """


            The Coding profile includes the following canonical terminology. Apply it only when
            pronunciation and surrounding context support the correction; ordinary words with a
            different meaning must remain ordinary words.
            <BUILT_IN_TECHNICAL_VOCABULARY>
            \(TechnicalTerminology.canonicalTerms.joined(separator: ", "))
            </BUILT_IN_TECHNICAL_VOCABULARY>

            \(TechnicalTerminology.phoneticGuidance)
            """
        }
        return prompt.finalPromptText + sections
    }
}
