import Foundation
import Combine
import AppKit
import Sparkle
import os

/// Owns the Sparkle updater and exposes update state for the sidebar / menu bar.
///
/// Background checks use Sparkle gentle-reminder hooks so we can show a persistent
/// sidebar banner without always forcing a modal alert.
///
/// Banner state is always re-validated against the running app's build number so
/// we never keep advertising an update the user has already installed.
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
                    // Session ended (dismissed, installed, aborted, or "already current").
                    // Drop a stale banner if we're no longer behind the advertised build.
                    self.clearIfNotActuallyNewer()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("SUUpdaterWillRestartNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.clearAvailableUpdate(status: nil)
            }
            .store(in: &cancellables)

        // Also clear on app activation if we somehow still advertise a non-newer build.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.clearIfNotActuallyNewer()
            }
            .store(in: &cancellables)

        logger.notice("Sparkle updater started feed=\(updater.feedURL?.absoluteString ?? "nil", privacy: .public) running=\(self.currentVersion, privacy: .public)(\(self.currentBuild, privacy: .public))")
    }

    func toggleAutoUpdates(_ value: Bool) {
        autoUpdateCheck = value
        updaterController.updater.automaticallyChecksForUpdates = value
    }

    /// User-initiated check — shows Sparkle’s standard progress / result UI.
    func checkForUpdates() {
        // If banner claims an update that isn't newer than us, drop it first.
        clearIfNotActuallyNewer()
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
        clearIfNotActuallyNewer()
        guard canCheckForUpdates || updaterController.updater.sessionInProgress == false else { return }
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
        clearIfNotActuallyNewer()
        guard updateAvailable else {
            // Nothing real pending — run a fresh check so the user gets honest feedback.
            checkForUpdates()
            return
        }
        lastErrorMessage = nil
        statusText = "Opening installer…"
        isChecking = true
        // Brings the update alert into focus / continues install.
        updaterController.checkForUpdates(nil)
    }

    func dismissUpdateBanner() {
        clearAvailableUpdate(status: nil)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.applyFoundUpdate(item)
            self.logger.notice("Valid update found: \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public)) current=\(self.currentBuild, privacy: .public)")
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in
            self.isChecking = false
            self.lastCheckedAt = Date()
            self.clearAvailableUpdate(status: "You're up to date")
            let ns = error as NSError
            let reason = ns.userInfo[SPUNoUpdateFoundReasonKey] as? Int
            self.logger.notice("No update found reason=\(reason.map(String.init) ?? "?", privacy: .public) err=\(error.localizedDescription, privacy: .public)")
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
            // User cancel / abort should not leave a permanent error card for benign cancels.
            let ns = error as NSError
            let isCancel = ns.domain == "SUSparkleErrorDomain" && (ns.code == 1001 || ns.code == 4)
            if isCancel {
                self.lastErrorMessage = nil
                self.statusText = nil
                // Keep banner only if the candidate is still strictly newer.
                self.clearIfNotActuallyNewer()
            } else {
                self.lastErrorMessage = message
                self.statusText = nil
                self.clearIfNotActuallyNewer()
            }
            self.logger.error("Update aborted: \(message, privacy: .public) code=\(ns.code, privacy: .public)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Task { @MainActor in
            self.logger.notice("Appcast loaded items=\(appcast.items.count, privacy: .public)")
            // If the feed's latest item is not newer than us, force-clear any banner.
            if let latest = appcast.items.first {
                if !self.isStrictlyNewer(build: latest.versionString) {
                    self.clearAvailableUpdate(status: nil)
                }
            }
        }
    }

    // MARK: - SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Immediate focus: Sparkle modal. Otherwise sidebar owns presentation.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            // Ignore callbacks for items that are not actually newer (post-install stale UI).
            guard self.isStrictlyNewer(build: update.versionString) else {
                self.clearAvailableUpdate(status: "You're up to date")
                self.logger.notice("Ignoring non-newer update UI for \(update.versionString, privacy: .public) (running \(self.currentBuild, privacy: .public))")
                return
            }
            self.applyFoundUpdate(update)
            if !handleShowingUpdate {
                self.statusText = "Update available"
                self.logger.notice("Gentle reminder: update \(update.displayVersionString, privacy: .public) shown in sidebar")
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // User engaged Sparkle UI — leave banner until session ends / install.
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            self.isChecking = false
            self.lastCheckedAt = Date()
            // Critical: after install, dismiss, or "already current", drop stale banners.
            self.clearIfNotActuallyNewer()
            if !self.updateAvailable, self.statusText == "Opening installer…" || self.statusText == "Checking for updates…" {
                self.statusText = nil
            }
        }
    }

    // MARK: - Private

    private func applyFoundUpdate(_ item: SUAppcastItem) {
        guard isStrictlyNewer(build: item.versionString) else {
            clearAvailableUpdate(status: "You're up to date")
            logger.notice("Rejected update \(item.versionString, privacy: .public) — not newer than \(self.currentBuild, privacy: .public)")
            return
        }
        availableVersion = item.displayVersionString
        availableBuild = item.versionString
        updateAvailable = true
        lastErrorMessage = nil
        statusText = "Update available"
        isChecking = false
        lastCheckedAt = Date()
    }

    private func clearAvailableUpdate(status: String?) {
        updateAvailable = false
        availableVersion = nil
        availableBuild = nil
        statusText = status
        lastErrorMessage = nil
    }

    /// Drop the banner if the advertised build is missing or not greater than ours.
    private func clearIfNotActuallyNewer() {
        guard updateAvailable else { return }
        guard let build = availableBuild, isStrictlyNewer(build: build) else {
            clearAvailableUpdate(status: nil)
            return
        }
    }

    /// Numeric CFBundleVersion comparison (Sparkle uses sparkle:version the same way).
    private func isStrictlyNewer(build candidate: String) -> Bool {
        let current = currentBuild
        guard !candidate.isEmpty, !current.isEmpty else { return false }
        return candidate.compare(current, options: .numeric) == .orderedDescending
    }
}
