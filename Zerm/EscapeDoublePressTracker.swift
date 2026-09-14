import Foundation

/// Double-press Escape to cancel: the first press opens a short window and a second
/// press inside it confirms. The "press again" hint is offered once per recorder session.
@MainActor
final class EscapeDoublePressTracker {
    enum Press: Equatable {
        /// First press. `showsHint` is true only for the first press of the session.
        case armed(showsHint: Bool)
        /// Second press inside the window.
        case confirmed
    }

    typealias Sleep = @MainActor (TimeInterval) async throws -> Void

    let window: TimeInterval
    private let sleep: Sleep
    private var armedPressID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var hasShownHint = false

    var isArmed: Bool { armedPressID != nil }

    init(
        window: TimeInterval = 1.5,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.window = window
        self.sleep = sleep
    }

    func press() -> Press {
        if isArmed {
            disarm()
            return .confirmed
        }

        let pressID = UUID()
        armedPressID = pressID
        timeoutTask = Task { [weak self, sleep, window] in
            do {
                try await sleep(window)
            } catch {
                return
            }
            // A reset or a newer press owns the state now; a stale timer must not clear it.
            guard let self, self.armedPressID == pressID else { return }
            self.armedPressID = nil
            self.timeoutTask = nil
        }

        let showsHint = !hasShownHint
        hasShownHint = true
        return .armed(showsHint: showsHint)
    }

    /// Ends the session: disarms and lets the next session show the hint again.
    func reset() {
        disarm()
        hasShownHint = false
    }

    private func disarm() {
        armedPressID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    deinit {
        timeoutTask?.cancel()
    }
}
