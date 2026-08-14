import Foundation
import os

/// Thread-safe process-wide meeting activity signal for services that cannot depend on SwiftUI.
/// Recording remains the source of truth and announces lifecycle changes through typed names.
final class MeetingActivityMonitor: @unchecked Sendable {
    static let shared = MeetingActivityMonitor()

    private let state = OSAllocatedUnfairLock(initialState: false)
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool { state.withLock { $0 } }

    private init(center: NotificationCenter = .default) {
        self.center = center
        observers.append(center.addObserver(
            forName: .meetingRecordingWillStart,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.state.withLock { $0 = true }
        })
        observers.append(center.addObserver(
            forName: .meetingRecordingDidStop,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.state.withLock { $0 = false }
        })
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
