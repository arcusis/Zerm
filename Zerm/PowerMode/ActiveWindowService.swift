import Foundation
import AppKit
import os

class ActiveWindowService: ObservableObject {
    static let shared = ActiveWindowService()
    @Published var currentApplication: NSRunningApplication?
    private var enhancementService: AIEnhancementService?
    private let browserURLService = BrowserURLService.shared
    private var browserURLTask: Task<Void, Never>?

    private let logger = Logger(
        subsystem: "com.arcusis.zerm",
        category: "browser.detection"
    )

    private init() {}

    func configure(with enhancementService: AIEnhancementService) {
        self.enhancementService = enhancementService
    }
    
    /// Applies the Power Mode configuration for the frontmost context.
    ///
    /// The app-level (or default) match is resolved and awaited here, because a config
    /// can swap the transcription model and that has to settle before the session is
    /// built. Browser URL matching is deliberately *not* awaited: it shells out to
    /// AppleScript, which can hang on an unresponsive browser or an Automation
    /// permission prompt, and this sits on the path that starts dictation. The URL match
    /// continues in the background and upgrades the active config if it lands in time,
    /// gated on `shouldApplyURLMatch` so a finished recording is never reconfigured.
    func applyConfiguration(
        powerModeId: UUID? = nil,
        shouldApplyURLMatch: @escaping @Sendable @MainActor () -> Bool = { true }
    ) async {
        if let powerModeId = powerModeId,
           let config = PowerModeManager.shared.getConfiguration(with: powerModeId) {
            await MainActor.run {
                PowerModeManager.shared.setActiveConfiguration(config)
            }
            await PowerModeSessionManager.shared.beginSession(with: config)
            return
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontmostApp.bundleIdentifier else {
            return
        }

        await MainActor.run {
            currentApplication = frontmostApp
        }

        if let config = PowerModeManager.shared.getConfigurationForApp(bundleIdentifier)
            ?? PowerModeManager.shared.getDefaultConfiguration() {
            await MainActor.run {
                PowerModeManager.shared.setActiveConfiguration(config)
            }
            await PowerModeSessionManager.shared.beginSession(with: config)
        }

        guard let browserType = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }

        // Only one URL lookup may be in flight; a new recording supersedes the last.
        browserURLTask?.cancel()
        browserURLTask = Task { [weak self] in
            guard let self else { return }
            do {
                let currentURL = try await self.browserURLService.getCurrentURL(from: browserType)
                try Task.checkCancellation()

                guard let config = PowerModeManager.shared.getConfigurationForURL(currentURL),
                      await shouldApplyURLMatch() else {
                    return
                }
                await MainActor.run {
                    PowerModeManager.shared.setActiveConfiguration(config)
                }
                await PowerModeSessionManager.shared.beginSession(with: config)
            } catch is CancellationError {
                return
            } catch {
                self.logger.error("❌ Failed to get URL from \(browserType.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
