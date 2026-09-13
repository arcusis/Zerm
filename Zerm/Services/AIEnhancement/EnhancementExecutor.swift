import Foundation
import LLMkit
import os

/// Sends one frozen request to its endpoint.
protocol EnhancementClient: Sendable {
    /// `isStopped` turns true when the request is cancelled or out of time; clients that cannot be
    /// interrupted by task cancellation (the on-device model) poll it.
    func complete(_ request: EnhancementRequest, isStopped: @escaping @Sendable () -> Bool) async throws -> String

    /// A fast check for endpoints that are commonly just not running, so a dictation does not wait
    /// out a whole timeout to find that out.
    func isReachable(_ endpoint: EnhancementEndpoint) async -> Bool
}

struct LiveEnhancementClient: EnhancementClient {
    private static let ollamaReachabilityTimeout: TimeInterval = 1.5

    func complete(_ request: EnhancementRequest, isStopped: @escaping @Sendable () -> Bool) async throws -> String {
        switch request.endpoint {
        case .onDevice(let packageFileName):
            return try await LocalLLMModelManager.shared.generate(
                system: request.systemMessage,
                user: request.userMessage,
                maxNewTokens: request.maxOutputTokens,
                role: .enhancement,
                packageFileName: packageFileName,
                isCancelled: isStopped
            )
        case .ollama(let baseURL, let model):
            guard let url = URL(string: baseURL) else {
                throw EnhancementFailure.other(String(localized: "Invalid Ollama server URL"))
            }
            return try await OllamaClient.generate(
                baseURL: url,
                model: model,
                prompt: request.userMessage,
                systemPrompt: request.systemMessage,
                options: OllamaGenerationOptions(temperature: 0.3),
                timeout: request.timeout
            )
        case .localCLI(let commandTemplate, let timeout):
            return try await LocalCLIService.run(
                commandTemplate: commandTemplate,
                timeout: timeout,
                systemPrompt: request.systemMessage,
                userPrompt: request.userMessage
            )
        case .anthropic(let apiKey, let model):
            return try await AnthropicLLMClient.chatCompletion(
                apiKey: apiKey,
                model: model,
                messages: [.user(request.userMessage)],
                systemPrompt: request.systemMessage,
                timeout: request.timeout
            )
        case .openAICompatible(let baseURL, let apiKey, let model):
            guard let url = URL(string: baseURL) else {
                throw EnhancementFailure.other(String(localized: "\(request.provider.rawValue) has an invalid API endpoint URL."))
            }
            return try await OpenAILLMClient.chatCompletion(
                baseURL: url,
                apiKey: apiKey,
                model: model,
                messages: [.user(request.userMessage)],
                systemPrompt: request.systemMessage,
                temperature: model.lowercased().hasPrefix("gpt-5") ? 1.0 : 0.3,
                reasoningEffort: ReasoningConfig.getReasoningParameter(for: model),
                extraBody: ReasoningConfig.getExtraBodyParameters(for: model),
                timeout: request.timeout
            )
        }
    }

    func isReachable(_ endpoint: EnhancementEndpoint) async -> Bool {
        guard case .ollama(let baseURL, _) = endpoint else { return true }
        guard let url = URL(string: baseURL) else { return false }
        return await OllamaClient.checkConnection(baseURL: url, timeout: Self.ollamaReachabilityTimeout)
    }
}

/// Runs a request to one of the outcomes in `EnhancementOutcome`: reachability, deadline,
/// cancellation, retries, output filter, emptiness and the language guard, in that order.
@MainActor
struct EnhancementExecutor {
    let client: EnhancementClient
    var maxAttempts = 3
    var initialRetryDelay: TimeInterval = 1

    private static let logger = Logger(subsystem: "com.arcusis.zerm", category: "EnhancementExecutor")
    nonisolated private static let pollInterval: UInt64 = 50_000_000

    func run(
        _ request: EnhancementRequest,
        isCancelled: @escaping @MainActor @Sendable () -> Bool
    ) async -> EnhancementOutcome {
        let started = Date()
        guard !isCancelled() else { return .cancelled }
        guard await client.isReachable(request.endpoint) else {
            Self.logger.notice("Enhancement provider unreachable: \(request.provider.rawValue, privacy: .public)")
            return .failed(.providerUnreachable(request.provider))
        }

        var attempt = 0
        var retryDelay = initialRetryDelay
        while true {
            attempt += 1
            do {
                let raw = try await withDeadline(request.timeout, isCancelled: isCancelled) { isStopped in
                    try await client.complete(request, isStopped: isStopped)
                }
                guard !isCancelled() else { return .cancelled }
                let text = AIEnhancementOutputFilter.filter(raw)
                // A provider that returns nothing has failed. Treating "" as success blanked
                // every History row in 2.8.3.
                guard !text.isEmpty else { return .failed(.emptyResponse) }
                if let rejection = EnhancementLanguageGuard.rejection(
                    original: request.inputText,
                    enhanced: text,
                    policy: request.languagePolicy
                ) {
                    Self.logger.notice("Enhancement discarded by the language guard: \(rejection.rawValue, privacy: .public)")
                    return .rejected(rejection)
                }
                return .enhanced(text: text, duration: Date().timeIntervalSince(started))
            } catch is CancellationError {
                return .cancelled
            } catch {
                let failure = EnhancementFailure(error)
                let retryable = failure.isTransient || (failure == .timeout && request.retriesOnTimeout)
                guard retryable, attempt < maxAttempts, !isCancelled() else {
                    Self.logger.error("Enhancement failed after \(attempt, privacy: .public) attempt(s): \(String(describing: failure), privacy: .public)")
                    return .failed(failure)
                }
                Self.logger.warning("Enhancement attempt \(attempt, privacy: .public) failed, retrying")
                if failure != .timeout {
                    guard await sleep(retryDelay, unless: isCancelled) else { return .cancelled }
                    retryDelay *= 2
                }
            }
        }
    }

    private enum StopReason: Sendable {
        case cancelled
        case timedOut
    }

    /// Races the operation against the deadline and the caller's cancellation. The operation's
    /// `isStopped` flag flips first, so clients that only poll still stop promptly.
    private func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        isCancelled: @escaping @MainActor @Sendable () -> Bool,
        operation: @escaping @Sendable (_ isStopped: @escaping @Sendable () -> Bool) async throws -> T
    ) async throws -> T {
        let stopReason = OSAllocatedUnfairLock<StopReason?>(initialState: nil)
        let isStopped: @Sendable () -> Bool = { stopReason.withLock { $0 != nil } }
        let deadline = Date().addingTimeInterval(seconds)

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation(isStopped) }
            group.addTask {
                while Date() < deadline {
                    if await isCancelled() {
                        stopReason.withLock { $0 = $0 ?? .cancelled }
                        throw CancellationError()
                    }
                    try await Task.sleep(nanoseconds: Self.pollInterval)
                }
                stopReason.withLock { $0 = $0 ?? .timedOut }
                throw EnhancementFailure.timeout
            }
            defer { group.cancelAll() }
            do {
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            } catch {
                // A client that notices `isStopped` throws its own error, and it can arrive before
                // the watcher's. The reason it was stopped is what counts.
                switch stopReason.withLock({ $0 }) {
                case .timedOut: throw EnhancementFailure.timeout
                case .cancelled: throw CancellationError()
                case nil: throw error
                }
            }
        }
    }

    /// Returns false when cancelled before the delay ran out.
    private func sleep(_ seconds: TimeInterval, unless isCancelled: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if isCancelled() { return false }
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
        return !isCancelled()
    }
}
