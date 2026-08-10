import AppKit
import Combine

/// Foreground applications that can be selected as a process-scoped meeting-audio target.
///
/// This intentionally makes no claim that a running process is currently in a call. The user
/// selects the application explicitly; browsers are included for browser-based meetings.
@MainActor
final class MeetingCaptureApplicationSource: ObservableObject {
    struct Application: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let processID: Int32

        var id: String { "\(bundleID):\(processID)" }

        var captureTarget: MeetingCaptureTarget {
            .application(bundleID: bundleID, appName: name, processID: processID)
        }
    }

    @Published private(set) var applications: [Application] = []

    private var observers: [NSObjectProtocol] = []

    func start() {
        if installUITestFixturesIfNeeded() { return }

        guard observers.isEmpty else {
            refresh()
            return
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    func refresh() {
        if installUITestFixturesIfNeeded() { return }

        let ownBundleID = Bundle.main.bundleIdentifier
        var seenBundleIDs = Set<String>()

        applications = NSWorkspace.shared.runningApplications
            .filter { application in
                application.activationPolicy == .regular
                    && !application.isTerminated
                    && application.bundleIdentifier != ownBundleID
            }
            .compactMap { application -> Application? in
                guard let bundleID = application.bundleIdentifier,
                      !bundleID.isEmpty,
                      !seenBundleIDs.contains(bundleID) else {
                    return nil
                }
                seenBundleIDs.insert(bundleID)
                return Application(
                    bundleID: bundleID,
                    name: application.localizedName ?? bundleID,
                    processID: application.processIdentifier
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func installUITestFixturesIfNeeded() -> Bool {
        guard UITestLaunchConfiguration.current.isEnabled else { return false }
        applications = [
            Application(
                bundleID: "com.example.meeting",
                name: "Example Meeting",
                processID: 4242
            ),
            Application(
                bundleID: "com.apple.Safari",
                name: "Safari",
                processID: 4343
            )
        ]
        return true
    }
}
