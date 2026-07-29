import Foundation
import AppKit
import os

enum BrowserType {
    case safari
    case arc
    case chrome
    case edge
    case firefox
    case brave
    case opera
    case vivaldi
    case orion
    case zen
    case yandex
    
    var scriptName: String {
        switch self {
        case .safari: return "safariURL"
        case .arc: return "arcURL"
        case .chrome: return "chromeURL"
        case .edge: return "edgeURL"
        case .firefox: return "firefoxURL"
        case .brave: return "braveURL"
        case .opera: return "operaURL"
        case .vivaldi: return "vivaldiURL"
        case .orion: return "orionURL"
        case .zen: return "zenURL"
        case .yandex: return "yandexURL"
        }
    }
    
    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .arc: return "company.thebrowser.Browser"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .firefox: return "org.mozilla.firefox"
        case .brave: return "com.brave.Browser"
        case .opera: return "com.operasoftware.Opera"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .orion: return "com.kagi.kagimacOS"
        case .zen: return "app.zen-browser.zen"
        case .yandex: return "ru.yandex.desktop.yandex-browser"
        }
    }
    
    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .arc: return "Arc"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        case .orion: return "Orion"
        case .zen: return "Zen Browser"
        case .yandex: return "Yandex Browser"
        }
    }
    
    static var allCases: [BrowserType] {
        [.safari, .arc, .chrome, .edge, .brave, .opera, .vivaldi, .orion, .yandex]
    }
    
    static var installedBrowsers: [BrowserType] {
        allCases.filter { browser in
            let workspace = NSWorkspace.shared
            return workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil
        }
    }
}

enum BrowserURLError: Error {
    case scriptNotFound
    case executionFailed
    case browserNotRunning
    case noActiveWindow
    case noActiveTab
    case timedOut
}

class BrowserURLService {
    static let shared = BrowserURLService()
    
    private let logger = Logger(
        subsystem: "com.arcusis.zerm",
        category: "browser.applescript"
    )
    
    private init() {}
    
    func getCurrentURL(from browser: BrowserType) async throws -> String {
        logger.debug("🔍 Attempting to get URL from \(browser.displayName, privacy: .public)")

        // Find the FRONTMOST instance of this browser by PID.
        // When multiple instances share the same bundle ID (e.g. a normal Chrome window
        // alongside a Playwright/automation Chrome), AppleScript's
        // `tell application "Google Chrome"` picks an arbitrary process, often routing
        // to the automation one with no visible window — causing error -1719.
        // Targeting by PID ensures we always query the user-facing window. (VoiceInk #658)
        guard let targetApp = frontmostInstance(of: browser) else {
            logger.error("❌ No visible \(browser.displayName, privacy: .public) instance found")
            throw BrowserURLError.browserNotRunning
        }

        let pid = targetApp.processIdentifier
        let inlineScript = inlineURLScript(for: browser, pid: pid)

        do {
            logger.debug("▶️ Executing AppleScript for \(browser.displayName, privacy: .public) PID=\(pid, privacy: .public)")
            let output = try await runOSAScript(inlineScript)

            if output.isEmpty {
                logger.error("❌ Empty output from AppleScript for \(browser.displayName, privacy: .public)")
                throw BrowserURLError.noActiveTab
            }
            if output.lowercased().contains("error") {
                // The active-tab URL can carry tokens/session IDs — keep it out of logs.
                logger.error("❌ AppleScript error for \(browser.displayName, privacy: .public): \(output, privacy: .private)")
                throw BrowserURLError.executionFailed
            }
            logger.debug("✅ Retrieved URL from \(browser.displayName, privacy: .public): \(output, privacy: .private)")
            return output
        } catch let error as BrowserURLError {
            throw error
        } catch {
            logger.error("❌ AppleScript execution failed for \(browser.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw BrowserURLError.executionFailed
        }
    }

    /// Runs an AppleScript via `osascript` without ever blocking a thread, and kills it
    /// if it overruns `timeout`.
    ///
    /// The previous implementation called `Process.waitUntilExit()` from an `async`
    /// function, which parks a Swift concurrency cooperative thread until the script
    /// returns — unbounded. AppleScript against a beachballed browser, or one showing
    /// an Automation permission prompt, can hang indefinitely, and this runs on the
    /// path that starts dictation. Completion is driven by `terminationHandler`
    /// instead, so no thread waits on the script.
    private func runOSAScript(_ script: String, timeout: TimeInterval = 2.0) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                // terminationHandler and the timeout can both fire; only the first wins.
                let hasResumed = OSAllocatedUnfairLock(initialState: false)
                @Sendable func finish(_ result: Result<String, Error>) {
                    let alreadyResumed = hasResumed.withLock { resumed -> Bool in
                        defer { resumed = true }
                        return resumed
                    }
                    guard !alreadyResumed else { return }
                    continuation.resume(with: result)
                }

                process.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    finish(.success(output))
                }

                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [logger] in
                    guard process.isRunning else { return }
                    logger.error("❌ AppleScript timed out after \(timeout, privacy: .public)s — terminating osascript")
                    process.terminate()
                    finish(.failure(BrowserURLError.timedOut))
                }

                do {
                    try process.run()
                } catch {
                    finish(.failure(BrowserURLError.executionFailed))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Returns the frontmost (user-visible) running instance of the browser,
    /// preferring the active app, falling back to any regular-policy instance.
    private func frontmostInstance(of browser: BrowserType) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == browser.bundleIdentifier &&
            $0.activationPolicy == .regular
        }
        // Prefer the currently-active one; fall back to any regular-policy instance.
        return apps.first(where: { $0.isActive }) ?? apps.first
    }

    /// Generates an inline AppleScript that targets the browser by the specific PID
    /// rather than by display name, avoiding ambiguity when multiple instances run.
    private func inlineURLScript(for browser: BrowserType, pid: pid_t) -> String {
        switch browser {
        case .safari:
            return "tell application id \"\(browser.bundleIdentifier)\" to return URL of current tab of front window"
        case .firefox:
            // Firefox AppleScript support is limited; use the display-name path
            return "tell application \"\(browser.displayName)\" to return URL of selected tab of front window"
        default:
            // Chrome-family browsers (Chrome, Edge, Brave, Arc, Opera, Vivaldi, Orion, Zen, Yandex)
            // use the same tab model; target by PID via `tell process` → `tell application`
            // Note: we address by bundle ID for precision, then navigate to front window active tab.
            return """
            tell application id "\(browser.bundleIdentifier)"
                tell front window
                    return URL of active tab
                end tell
            end tell
            """
        }
    }

    func isRunning(_ browser: BrowserType) -> Bool {
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == browser.bundleIdentifier
        }
        logger.debug("\(browser.displayName, privacy: .public) running: \(isRunning, privacy: .public)")
        return isRunning
    }
} 
