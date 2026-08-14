import Foundation

/// Serializes mutable provider runtimes and gives interactive Dictation priority over background
/// meeting work. A provider may run one inference at a time; queues are bounded by the meeting
/// transcriber's window policy rather than by retaining audio here.
actor TranscriptionInferenceScheduler {
    static let shared = TranscriptionInferenceScheduler()

    enum Priority: Int { case meeting = 0, dictation = 1 }

    private struct Waiter {
        let id: UUID
        let priority: Priority
        let order: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeProviders = Set<ModelProvider>()
    private var waiters: [ModelProvider: [Waiter]] = [:]
    private var nextOrder: UInt64 = 0
    private var cancelledWaiters = Set<UUID>()
    private var pendingRegistrationIDs = Set<UUID>()

    func run<T>(
        provider: ModelProvider,
        priority: Priority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(provider: provider, priority: priority)
        do {
            let value = try await operation()
            release(provider: provider)
            return value
        } catch {
            release(provider: provider)
            throw error
        }
    }

    private func acquire(provider: ModelProvider, priority: Priority) async throws {
        try Task.checkCancellation()
        guard activeProviders.contains(provider) else {
            activeProviders.insert(provider)
            return
        }
        let id = UUID()
        pendingRegistrationIDs.insert(id)
        let order = nextOrder
        nextOrder &+= 1
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingRegistrationIDs.remove(id)
                if cancelledWaiters.remove(id) != nil || Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                waiters[provider, default: []].append(.init(
                    id: id,
                    priority: priority,
                    order: order,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id, provider: provider) }
        }
        guard acquired else { throw CancellationError() }
    }

    private func release(provider: ModelProvider) {
        guard var queue = waiters[provider], !queue.isEmpty else {
            activeProviders.remove(provider)
            waiters[provider] = nil
            return
        }
        queue.sort {
            if $0.priority.rawValue == $1.priority.rawValue { return $0.order < $1.order }
            return $0.priority.rawValue > $1.priority.rawValue
        }
        let next = queue.removeFirst()
        waiters[provider] = queue.isEmpty ? nil : queue
        next.continuation.resume(returning: true)
    }

    private func cancelWaiter(id: UUID, provider: ModelProvider) {
        guard var queue = waiters[provider],
              let index = queue.firstIndex(where: { $0.id == id }) else {
            if pendingRegistrationIDs.contains(id) { cancelledWaiters.insert(id) }
            return
        }
        let waiter = queue.remove(at: index)
        waiters[provider] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(returning: false)
    }
}
