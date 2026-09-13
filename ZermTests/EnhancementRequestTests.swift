import Foundation
import os
import Testing
@testable import Zerm

/// A client that records what it was sent and answers from a script. No network.
final class FakeEnhancementClient: EnhancementClient, @unchecked Sendable {
    enum Reply {
        case text(String)
        case failure(Error)
        /// Waits until stopped, like a model that never finishes.
        case hang
    }

    private let lock = OSAllocatedUnfairLock(initialState: (replies: [Reply](), sent: [EnhancementRequest]()))
    private let reachable: Bool

    init(_ replies: [Reply], reachable: Bool = true) {
        lock.withLock { $0.replies = replies }
        self.reachable = reachable
    }

    var sent: [EnhancementRequest] { lock.withLock { $0.sent } }

    func complete(_ request: EnhancementRequest, isStopped: @escaping @Sendable () -> Bool) async throws -> String {
        let reply = lock.withLock { state -> Reply in
            state.sent.append(request)
            return state.replies.isEmpty ? .text("") : state.replies.removeFirst()
        }
        switch reply {
        case .text(let text):
            return text
        case .failure(let error):
            throw error
        case .hang:
            while !isStopped() {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
    }

    func isReachable(_ endpoint: EnhancementEndpoint) async -> Bool { reachable }
}

@MainActor
struct EnhancementRequestTests {

    private let cleanupPrompt = CustomPrompt(
        id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!,
        title: "Cleanup",
        promptText: "Clean the text."
    )
    private let emailPrompt = CustomPrompt(
        id: UUID(uuidString: "11111111-0000-0000-0000-000000000002")!,
        title: "Email",
        promptText: "Write an email.",
        providerOverride: AIProvider.anthropic.rawValue,
        modelOverride: "claude-haiku-4-5",
        allowsLanguageChange: true
    )

    private func settings(
        provider: AIProvider = .openAI,
        selectedPrompt: UUID? = nil,
        timeout: TimeInterval = 15
    ) -> EnhancementSettingsSnapshot {
        EnhancementSettingsSnapshot(
            prompts: [cleanupPrompt, emailPrompt],
            selectedPromptID: selectedPrompt ?? cleanupPrompt.id,
            provider: provider,
            modelForProvider: { provider in
                switch provider {
                case .openAI: return "gpt-5.4"
                case .anthropic: return "claude-sonnet-4-6"
                case .groq: return "openai/gpt-oss-120b"
                default: return provider.defaultModel
                }
            },
            endpointForProvider: { provider, model in
                provider == .anthropic
                    ? .success(.anthropic(apiKey: "test", model: model))
                    : .success(.openAICompatible(baseURL: "https://example.invalid/v1/chat/completions", apiKey: "test", model: model))
            },
            customVocabulary: "",
            timeoutSeconds: timeout,
            retriesOnTimeout: false
        )
    }

    private func request(
        _ input: String,
        purpose: EnhancementPurpose = .enhanced,
        overrides: EnhancementOverrides = EnhancementOverrides(),
        settings: EnhancementSettingsSnapshot? = nil
    ) throws -> EnhancementRequest {
        try EnhancementRequestBuilder.make(
            input: input,
            purpose: purpose,
            overrides: overrides,
            settings: settings ?? self.settings()
        ).get()
    }

    // MARK: - Freezing

    @Test func aRequestIsUnaffectedBySettingsChangedAfterItWasBuilt() async throws {
        var liveSettings = settings()
        let frozen = try EnhancementRequestBuilder.make(
            input: "ship the build on friday",
            purpose: .refine,
            overrides: EnhancementOverrides(),
            settings: liveSettings,
            clipboardContext: "Release notes"
        ).get()

        // Everything a Power Mode session end, a recorder dismissal or the user could change.
        liveSettings.provider = .groq
        liveSettings.selectedPromptID = emailPrompt.id
        liveSettings.prompts = []
        liveSettings.timeoutSeconds = 60

        let client = FakeEnhancementClient([.text("Ship the build on Friday.")])
        let outcome = await EnhancementExecutor(client: client).run(frozen, isCancelled: { false })

        let duration = try #require(outcome.duration)
        #expect(outcome == .enhanced(text: "Ship the build on Friday.", duration: duration))
        let sent = try #require(client.sent.first)
        #expect(sent.provider == .openAI)
        #expect(sent.model == "gpt-5.4")
        #expect(sent.promptID == cleanupPrompt.id)
        #expect(sent.systemMessage.contains("Clean the text."))
        #expect(sent.systemMessage.contains("<CLIPBOARD_CONTEXT>\nRelease notes"))
        #expect(sent.timeout == EnhancementRequestBuilder.refineTimeout)
    }

    @Test func enhancedModeUsesTheTimeoutSettingAndRefineItsOwnBudget() throws {
        let custom = settings(timeout: 40)
        #expect(try request("hello there friend", purpose: .enhanced, settings: custom).timeout == 40)
        #expect(try request("hello there friend", purpose: .refine, settings: custom).timeout == EnhancementRequestBuilder.refineTimeout)
    }

    // MARK: - Provider and model resolution (#185)

    @Test func promptModelOverridesTheGlobalSelection() throws {
        let built = try request("write to bob", overrides: EnhancementOverrides(promptID: emailPrompt.id))
        #expect(built.provider == .anthropic)
        #expect(built.model == "claude-haiku-4-5")
        #expect(built.languagePolicy == .mayChangeLanguage)
    }

    @Test func powerModeProviderBeatsThePromptModel() throws {
        let built = try request(
            "write to bob",
            overrides: EnhancementOverrides(promptID: emailPrompt.id, provider: .groq, model: nil)
        )
        #expect(built.provider == .groq)
        #expect(built.model == "openai/gpt-oss-120b")
    }

    @Test func aModelWithoutItsProviderIsIgnored() throws {
        let built = try request("hello there friend", overrides: EnhancementOverrides(model: "claude-haiku-4-5"))
        #expect(built.provider == .openAI)
        #expect(built.model == "gpt-5.4")
        #expect(built.languagePolicy == .preserveScript)
    }

    @Test func transcriptionOnlyProvidersCannotEnhance() {
        let result = EnhancementRequestBuilder.make(
            input: "hello there friend",
            purpose: .enhanced,
            overrides: EnhancementOverrides(provider: .elevenLabs),
            settings: settings()
        )
        #expect(throws: EnhancementUnavailableReason.transcriptionOnlyProvider(provider: .elevenLabs)) { try result.get() }
        #expect(!AIProvider.enhancementProviders.contains(.elevenLabs))
        #expect(!AIProvider.enhancementProviders.contains(.deepgram))
        #expect(!AIProvider.enhancementProviders.contains(.soniox))
        #expect(!AIProvider.enhancementProviders.contains(.speechmatics))
        #expect(AIProvider.enhancementProviders.contains(.localLLM))
    }

    /// The newest listed models must not fall back to a provider's default reasoning effort,
    /// which adds seconds of thinking to a one-sentence cleanup.
    @Test func currentModelIdsHaveReasoningSettings() {
        for (provider, model) in [(AIProvider.openAI, "gpt-5.5"), (.gemini, "gemini-3.5-flash"), (.gemini, "gemini-3.1-flash-lite")] {
            #expect(provider.availableModels.contains(model), "\(model)")
            #expect(ReasoningConfig.getReasoningParameter(for: model) != nil, "\(model)")
        }
    }

    // MARK: - Outcomes

    @Test func languageGuardRejectionIsNotAnEnhancement() async throws {
        let client = FakeEnhancementClient([.text("שלח את הדוח היום")])
        let outcome = await EnhancementExecutor(client: client).run(try request("send the report today"), isCancelled: { false })
        #expect(outcome == .rejected(.languageChanged))

        let record = Transcription(text: "send the report today", duration: 2)
        record.record(outcome, of: try request("send the report today"))
        #expect(record.enhancedText == nil)
        #expect(record.enhancementRecordState == .rejected)
        #expect(record.enhancementOutcomeReason == "languageChanged")
        #expect(record.displayText == "send the report today")
    }

    @Test func mixedHebrewAndEnglishSurvivesTheGuard() async throws {
        let input = "תזכיר לי לשלוח את the quarterly report מחר"
        let client = FakeEnhancementClient([.text("תזכיר לי לשלוח את the quarterly report מחר.")])
        let outcome = await EnhancementExecutor(client: client).run(try request(input), isCancelled: { false })
        guard case .enhanced(let text, _) = outcome else {
            Issue.record("expected an enhancement, got \(outcome)")
            return
        }
        #expect(text == "תזכיר לי לשלוח את the quarterly report מחר.")
    }

    @Test func emptyOutputIsAFailure() async throws {
        let client = FakeEnhancementClient([.text("<think>tidy</think>")])
        let outcome = await EnhancementExecutor(client: client).run(try request("hello there friend"), isCancelled: { false })
        #expect(outcome == .failed(.emptyResponse))
    }

    @Test func unreachableProviderFailsWithoutSending() async throws {
        let client = FakeEnhancementClient([.text("never")], reachable: false)
        let built = try request("hello there friend")
        let outcome = await EnhancementExecutor(client: client).run(built, isCancelled: { false })
        #expect(outcome == .failed(.providerUnreachable(.openAI)))
        #expect(client.sent.isEmpty)
    }

    @Test func aHungProviderTimesOutAtTheRequestTimeout() async throws {
        let client = FakeEnhancementClient([.hang])
        let built = try request("hello there friend", settings: settings(timeout: 0.2))
        let started = Date()
        let outcome = await EnhancementExecutor(client: client).run(built, isCancelled: { false })
        #expect(outcome == .failed(.timeout))
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func cancellationStopsAHungProvider() async throws {
        let client = FakeEnhancementClient([.hang])
        let deadline = Date().addingTimeInterval(0.1)
        let outcome = await EnhancementExecutor(client: client).run(try request("hello there friend"), isCancelled: { Date() > deadline })
        #expect(outcome == .cancelled)
    }

    @Test func transientFailuresAreRetried() async throws {
        let client = FakeEnhancementClient([.failure(EnhancementFailure.server), .text("Hello there, friend.")])
        var executor = EnhancementExecutor(client: client)
        executor.initialRetryDelay = 0.01
        let outcome = await executor.run(try request("hello there friend"), isCancelled: { false })
        #expect(client.sent.count == 2)
        #expect(outcome.duration != nil)
    }

    @Test func retrySleepHonoursCancellation() async throws {
        let client = FakeEnhancementClient([.failure(EnhancementFailure.network), .text("late")])
        var executor = EnhancementExecutor(client: client)
        executor.initialRetryDelay = 5
        let deadline = Date().addingTimeInterval(0.1)
        let started = Date()
        let outcome = await executor.run(try request("hello there friend"), isCancelled: { Date() > deadline })
        #expect(outcome == .cancelled)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(client.sent.count == 1)
    }

    // MARK: - Pipeline order

    /// Deterministic cleanup runs before the LLM, so the model never sees dictation commands; the
    /// user's lowercase preference is applied to the paste and again to the LLM's output.
    @Test func deterministicCleanupRunsBeforeTheModelAndPreferencesAfter() async throws {
        let raw = "call the vendor scratch that email the vendor new line thanks"
        let cleaned = DictationTextProcessing.clean(raw, formatsText: false) { $0 }
        #expect(!cleaned.localizedCaseInsensitiveContains("scratch that"))
        #expect(!cleaned.localizedCaseInsensitiveContains("new line"))
        #expect(cleaned.contains("\n"))

        let preferences = TextCleanupPreferences(formatsText: false, punctuation: .removeTrailingPeriod, lowercases: true)
        let pasted = preferences.applyPreferences(to: cleaned)
        #expect(pasted == pasted.lowercased())

        let built = try request(cleaned)
        #expect(built.inputText == cleaned)
        #expect(built.userMessage.contains(cleaned))

        let client = FakeEnhancementClient([.text("Email the Vendor.\nThanks.")])
        let outcome = await EnhancementExecutor(client: client).run(built, isCancelled: { false })
        let record = Transcription(text: pasted, duration: 2)
        record.record(outcome, of: built, finalize: preferences.applyPreferences(to:))
        #expect(record.enhancedText == "email the vendor.\nthanks")
        #expect(record.enhancementRecordState == .enhanced)
        #expect(record.aiEnhancementModelName == "gpt-5.4")
    }

    // MARK: - Notifications

    @Test func notConfiguredIsShownOnceWithinTheQuietPeriod() {
        var shown: [EnhancementNotifier.Message] = []
        var clock = Date(timeIntervalSince1970: 1_000)
        let notifier = EnhancementNotifier(quietPeriod: 120, now: { clock }, present: { shown.append($0) })

        let missingModel = EnhancementOutcome.skipped(.notConfigured(.onDeviceModelMissing(modelName: "Gemma 4 E2B")))
        #expect(notifier.report(missingModel, purpose: .refine))
        #expect(!notifier.report(missingModel, purpose: .enhanced))
        #expect(notifier.report(.skipped(.notConfigured(.apiKeyMissing(provider: .openAI))), purpose: .manual))

        clock = clock.addingTimeInterval(121)
        #expect(notifier.report(missingModel, purpose: .enhanced))
        #expect(shown.count == 3)
        #expect(shown.allSatisfy { $0.opensSettings })
    }

    @Test func everySkipAndFailureTheUserExpectedIsReported() {
        var shown = 0
        let notifier = EnhancementNotifier(quietPeriod: 0, present: { _ in shown += 1 })
        let outcomes: [EnhancementOutcome] = [
            .skipped(.notConfigured(.commandMissing)),
            .skipped(.notConfigured(.modelMissing(provider: .ollama))),
            .failed(.providerUnreachable(.ollama)),
            .failed(.timeout),
            .failed(.network),
            .rejected(.languageChanged)
        ]
        for outcome in outcomes {
            #expect(notifier.report(outcome, purpose: .manual), "\(outcome)")
        }
        #expect(shown == outcomes.count)
    }

    @Test func deliberateSkipsAndSuccessesAreSilent() {
        let notifier = EnhancementNotifier(present: { _ in Issue.record("unexpected notification") })
        #expect(!notifier.report(.skipped(.shortTranscription), purpose: .enhanced))
        #expect(!notifier.report(.cancelled, purpose: .refine))
        #expect(!notifier.report(.enhanced(text: "Hi.", duration: 1), purpose: .manual))
    }
}

private extension EnhancementOutcome {
    var duration: TimeInterval? {
        if case .enhanced(_, let duration) = self { return duration }
        return nil
    }
}
