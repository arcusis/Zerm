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
        shouldForceStop: @escaping () -> Bool,
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
                if shouldForceStop() { self.forceStop?() }
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
            if option == .fn { return flags.contains(.maskSecondaryFn) }
            guard let keyCode = option.keyCode else { return false }
            let flagIsDown: Bool
            switch option {
            case .leftOption, .rightOption: flagIsDown = flags.contains(.maskAlternate)
            case .leftControl, .rightControl: flagIsDown = flags.contains(.maskControl)
            case .leftCommand, .rightCommand: flagIsDown = flags.contains(.maskCommand)
            case .rightShift: flagIsDown = flags.contains(.maskShift)
            case .fn: flagIsDown = flags.contains(.maskSecondaryFn)
            case .custom, .none: flagIsDown = false
            }
            return flagIsDown && keyState(CGKeyCode(keyCode))
        }
    }

    static func isHybridPushToTalk(pressDuration: TimeInterval, threshold: TimeInterval) -> Bool {
        pressDuration >= threshold
    }

    static func shouldWatch(mode: HotkeyManager.HotkeyMode) -> Bool {
        mode != .toggle
    }
}
