import Foundation

@MainActor
final class ClipboardHistoryRuntime {
    static let shared = ClipboardHistoryRuntime()

    let store: ClipboardHistoryStore?
    private let monitor: ClipboardMonitor?

    private init() {
        if let store = try? ClipboardHistoryStore() {
            self.store = store
            monitor = ClipboardMonitor(store: store)
        } else {
            store = nil
            monitor = nil
        }
    }

    func start() {
        monitor?.start()
    }

    func recordDictation(_ text: String) {
        guard let store else { return }
        Task { try? await store.recordDictation(text) }
    }
}
