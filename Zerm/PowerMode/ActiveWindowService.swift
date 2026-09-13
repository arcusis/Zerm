import Foundation
import AppKit
import os

class ActiveWindowService: ObservableObject {
    static let shared = ActiveWindowService()
    @Published var currentApplication: NSRunningApplication?
    private let browserURLService = BrowserURLService.shared

    /// How long a recording start waits for the browser to report its URL. AppleScript can hang
    /// on an unresponsive browser or an Automation permission prompt, and this sits on the path
    /// that starts dictation. Audio is already being captured and buffered meanwhile.
    static let browserURLWaitLimit: TimeInterval = 0.5

    private static let logger = Logger(
        subsystem: "com.arcusis.zerm",
        category: "browser.detection"
    )

    private init() {}

    /// The Power Mode for the recording that is starting: an explicitly requested one, else the
    /// frontmost app's, else the default. In a browser a URL match wins if the browser answers in
    /// time. A match that arrives later is ignored: it must not reconfigure a recording whose
    /// transcription session was already built.
    @MainActor
    func resolveConfiguration(powerModeId: UUID? = nil) async -> PowerModeConfig? {
        let appConfiguration = resolveConfigurationWithoutURL(powerModeId: powerModeId)
        guard powerModeId == nil,
              let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let browserType = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return appConfiguration
        }

        let browserURLService = browserURLService
        return await Self.configuration(
            appConfiguration: appConfiguration,
            configurations: PowerModeManager.shared.configurations,
            waitLimit: Self.browserURLWaitLimit,
            lookupURL: { try await browserURLService.getCurrentURL(from: browserType) }
        )
    }

    /// The requested, frontmost app's or default Power Mode, without asking a browser for its URL.
    /// For a recording that stopped before its full resolution finished.
    @MainActor
    func resolveConfigurationWithoutURL(powerModeId: UUID? = nil) -> PowerModeConfig? {
        let configurations = PowerModeManager.shared.configurations
        if let powerModeId, let config = configurations.first(where: { $0.id == powerModeId }) {
            return config
        }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontmostApp.bundleIdentifier else {
            return nil
        }
        currentApplication = frontmostApp
        return PowerModeManager.configuration(forApp: bundleIdentifier, in: configurations)
            ?? PowerModeManager.defaultConfiguration(in: configurations)
    }

    static func configuration(
        appConfiguration: PowerModeConfig?,
        configurations: [PowerModeConfig],
        waitLimit: TimeInterval,
        lookupURL: @escaping @Sendable () async throws -> String
    ) async -> PowerModeConfig? {
        let lookup = Task<String?, Never> {
            do {
                return try await lookupURL()
            } catch {
                logger.error("❌ Failed to get the browser URL: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        guard let answered = await BoundedWait.value(of: lookup, within: waitLimit) else {
            logger.notice("Browser URL arrived too late for this recording; using the app's Power Mode")
            return appConfiguration
        }
        return answered.flatMap { PowerModeManager.configuration(forURL: $0, in: configurations) }
            ?? appConfiguration
    }
}
