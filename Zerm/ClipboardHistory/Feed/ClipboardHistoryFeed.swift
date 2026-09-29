import Combine
import Foundation

enum ClipboardHistoryChange: Sendable {
    case inserted(storeID: UUID, item: ClipboardItem)
    case insertedBatch(storeID: UUID, items: [ClipboardItem])
    case updated(storeID: UUID, item: ClipboardItem)
    case removed(storeID: UUID, ids: [UUID])
    case cleared(storeID: UUID, removedIDs: [UUID])
}

@MainActor
final class ClipboardHistoryFeed: ObservableObject {
    static let shared = ClipboardHistoryFeed()

    @Published private(set) var latestChange: ClipboardHistoryChange?
    private var observers: [UUID: AsyncStream<ClipboardHistoryChange>.Continuation] = [:]

    func changes() -> AsyncStream<ClipboardHistoryChange> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers.removeValue(forKey: id) }
            }
        }
    }

    func publish(_ change: ClipboardHistoryChange) {
        latestChange = change
        for observer in observers.values { observer.yield(change) }
    }
}
