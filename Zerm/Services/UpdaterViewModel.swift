import Foundation
import Combine
import Sparkle
import os

/// Owns the Sparkle updater and exposes update state for the sidebar / menu bar.
///
/// Background checks use Sparkle gentle-reminder hooks so we can show a persistent
/// sidebar banner without always forcing a modal alert.
@MainActor
final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let autoUpdateCheckKey = "autoUpdateCheck"

    private var autoUpdateCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoUpdateCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateCheckKey) }
    }

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "Updater")
    private var updaterController: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isChecking = false
    /// True when a newer version is available (or download/install is in progress).
    @Published private(set) var updateAvailable = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var availableBuild: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var statusText: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// Gentle reminders: we show our own sidebar UI for background finds.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = autoUpdateCheck
        // Check daily; also check on launch via `checkInBackground()`.
        updater.updateCheckInterval = 24 * 60 * 60

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)

        updater.publisher(for: \.sessionInProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] inProgress in
                guard let self else { return }
                if inProgress {
                    self.isChecking = true
                } else {
                    self.isChecking = false
                    self.lastCheckedAt = Date()
                }
            }
            .store(in: &cancellables)

        logger.notice("Sparkle updater started feed=\(updater.feedURL?.absoluteString ?? "nil", privacy: .public)")
    }

    func toggleAutoUpdates(_ value: Bool) {
        autoUpdateCheck = value
        updaterController.updater.automaticallyChecksForUpdates = value
    }

    /// User-initiated check — shows Sparkle’s standard progress / result UI.
    func checkForUpdates() {
        guard canCheckForUpdates else {
            logger.warning("checkForUpdates ignored — canCheckForUpdates=false")
            return
        }
        lastErrorMessage = nil
        statusText = "Checking for updates…"
        isChecking = true
        updaterController.checkForUpdates(nil)
    }

    /// Silent background check (launch / interval). May only update the sidebar.
    func checkInBackground() {
        guard canCheckForUpdates || updaterController.updater.sessionInProgress == false else { return }
        // If the updater isn't ready yet, retry shortly after launch.
        if !canCheckForUpdates {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.canCheckForUpdates else { return }
                self.logger.notice("Background update check (delayed)")
                self.updaterController.updater.checkForUpdatesInBackground()
            }
            return
        }
        logger.notice("Background update check")
        updaterController.updater.checkForUpdatesInBackground()
    }

    /// Alias kept for existing call sites.
    func silentlyCheckForUpdates() {
        checkInBackground()
    }

    /// Opens Sparkle’s install flow for the pending update (sidebar CTA).
    func installPendingUpdate() {
        guard updateAvailable else {
            checkForUpdates()
            return
        }
        // Brings the update alert into focus / continues install.
        updaterController.checkForUpdates(nil)
    }

    func dismissUpdateBanner() {
        // Soft dismiss only — next check can bring it back.
        updateAvailable = false
        statusText = nil
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.applyFoundUpdate(item)
            self.logger.notice("Valid update found: \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in
            self.isChecking = false
            self.lastCheckedAt = Date()
            // Keep a soft banner if we previously knew about an update and the
            // check failed for a transient reason; clear when truly up to date.
            let ns = error as NSError
            let reason = ns.userInfo[SPUNoUpdateFoundReasonKey] as? Int
            // SPUNoUpdateFoundReason.onLatestVersion == typically 0/1 depending on version
            self.updateAvailable = false
            self.availableVersion = nil
            self.availableBuild = nil
            self.statusText = "You're up to date"
            self.lastErrorMessage = nil
            self.logger.notice("No update found reason=\(reason.map(String.init) ?? "?", privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            // Clear "up to date" status after a few seconds so the sidebar stays clean.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if self.statusText == "You're up to date" {
                    self.statusText = nil
                }
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            self.isChecking = false
            self.lastCheckedAt = Date()
            let message = error.localizedDescription
            self.lastErrorMessage = message
            self.statusText = nil
            self.logger.error("Update aborted: \(message, privacy: .public)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Task { @MainActor in
            self.logger.notice("Appcast loaded items=\(appcast.items.count, privacy: .public)")
        }
    }

    // MARK: - SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Immediate focus (idle/recent launch): let Sparkle show its alert.
        // Otherwise we own the presentation via the sidebar banner.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            self.applyFoundUpdate(update)
            if !handleShowingUpdate {
                self.statusText = "Update available"
                self.logger.notice("Gentle reminder: update \(update.displayVersionString, privacy: .public) shown in sidebar")
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // User interacted with Sparkle UI — keep banner until install finishes.
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            self.isChecking = false
            self.lastCheckedAt = Date()
        }
    }

    // MARK: - Private

    private func applyFoundUpdate(_ item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        availableBuild = item.versionString
        updateAvailable = true
        lastErrorMessage = nil
        statusText = "Update available"
        isChecking = false
        lastCheckedAt = Date()
    }
}
