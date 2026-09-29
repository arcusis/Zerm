import ApplicationServices
import AppKit
import Carbon

enum HotkeyStateProbe: Equatable {
    case modifier(HotkeyManager.HotkeyOption)
    case key(CGKeyCode)
}

@MainActor
final class HotkeyReleaseWatchdog {
    typealias Sleep = (TimeInterval) async throws -> Void

    private let clock: () -> TimeInterval
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var releaseObservedAt: TimeInterval?
    private var forceStop: (() -> Void)?

    private(set) var isActive = false

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, sleep: @escaping Sleep = { interval in
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }) {
        self.clock = clock
        self.sleep = sleep
    }

    func start(
        isKeyDown: @escaping () -> Bool,
        onRelease: @escaping (TimeInterval) -> Void,
        shouldForceStop: @escaping (TimeInterval) -> Bool,
        onForceStop: @escaping () -> Void
    ) {
        cancel()
        isActive = true
        forceStop = onForceStop
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await self.sleep(0.05) } catch { return }
                guard !Task.isCancelled else { return }

                if self.releaseObservedAt == nil, !isKeyDown() {
                    let releasedAt = self.clock()
                    self.releaseObservedAt = releasedAt
                    self.isActive = false
                    onRelease(releasedAt)
                }

                guard let releasedAt = self.releaseObservedAt else { continue }
                guard self.clock() - releasedAt >= 1 else { continue }
                if shouldForceStop(releasedAt) { self.forceStop?() }
                self.cancel()
                return
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isActive = false
        releaseObservedAt = nil
        forceStop = nil
    }

    static func isDown(_ probe: HotkeyStateProbe, flags: CGEventFlags, keyState: (CGKeyCode) -> Bool) -> Bool {
        switch probe {
        case .key(let keyCode):
            return keyState(keyCode)
        case .modifier(let option):
            // Modifier keyState can disagree with flagsState, particularly for remapped
            // keys. Match the flagsChanged event handler's sided flags and generic fallback.
            return HotkeyManager.isModifierPressed(option, flags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
        }
    }

    static func isHybridPushToTalk(pressDuration: TimeInterval, threshold: TimeInterval) -> Bool {
        pressDuration >= threshold
    }

    static func shouldWatch(mode: HotkeyManager.HotkeyMode) -> Bool {
        mode != .toggle
    }
}
