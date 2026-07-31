import AppKit
import Combine
import Foundation
import OSLog

/// Notices when a meeting starts, so recording can offer itself instead of being remembered.
///
/// Detection is by running application rather than by watching audio: a call app being *open*
/// is the signal a meeting is about to happen, and it arrives before anyone speaks — which is
/// the only useful moment to offer to record. Browser-based calls are caught through the browser
/// plus the tab URL, which `BrowserURLService` already resolves for Power Mode.
@MainActor
final class MeetingAppDetector: ObservableObject {

    /// What a detected meeting looks like.
    struct Detection: Equatable {
        let appName: String
        let bundleID: String
    }

    /// Native call apps, by bundle identifier.
    static let meetingBundleIDs: Set<String> = [
        "us.zoom.xos",                       // Zoom
        "com.microsoft.teams",               // Teams (classic)
        "com.microsoft.teams2",              // Teams (new)
        "com.cisco.webexmeetingsapp",        // Webex
        "com.webex.meetingmanager",
        "com.skype.skype",
        "com.hnc.Discord",
        "org.whispersystems.signal-desktop", // Signal
        "com.tinyspeck.slackmacgap",         // Slack huddles
        "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", // Meet PWA
        "com.apple.FaceTime"
    ]

    /// URLs that mean a browser tab is in a call.
    static let meetingURLFragments = [
        "meet.google.com",
        "zoom.us/j/",
        "teams.microsoft.com/l/meetup-join",
        "teams.live.com/meet",
        "whereby.com",
        "app.gather.town",
        "meet.jit.si"
    ]

    @Published private(set) var detected: Detection?

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingAppDetector")
    private var observers: [NSObjectProtocol] = []

    /// Detections already offered, so a meeting that is declined is not offered again every
    /// time the user switches back to the call window.
    private var dismissed: Set<String> = []

    var onMeetingStarted: ((Detection) -> Void)?

    // MARK: - Lifecycle

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.evaluate(app) }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            Task { @MainActor in self?.clear(bundleID: id) }
        })

        // A call app already running when Zerm starts still counts.
        for app in NSWorkspace.shared.runningApplications { evaluate(app) }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        detected = nil
    }

    /// The user said no. Do not offer this meeting again until the app goes away and comes back.
    func dismiss() {
        if let id = detected?.bundleID { dismissed.insert(id) }
        detected = nil
    }

    // MARK: - Detection

    private func evaluate(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier,
              Self.meetingBundleIDs.contains(id),
              !dismissed.contains(id),
              detected == nil else { return }

        let detection = Detection(appName: app.localizedName ?? id, bundleID: id)
        detected = detection
        logger.notice("Meeting app detected: \(id, privacy: .public)")
        onMeetingStarted?(detection)
    }

    private func clear(bundleID: String) {
        dismissed.remove(bundleID)
        if detected?.bundleID == bundleID { detected = nil }
    }

    // MARK: - Pure helpers

    static func isMeetingApp(bundleID: String) -> Bool {
        meetingBundleIDs.contains(bundleID)
    }

    /// Whether a browser URL is a live call rather than just a meeting-service page.
    ///
    /// Matched on the join path, not the bare domain — `zoom.us` alone is the marketing site,
    /// and offering to record it would train the user to dismiss the prompt.
    static func isMeetingURL(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return meetingURLFragments.contains { lowered.contains($0) }
    }
}
