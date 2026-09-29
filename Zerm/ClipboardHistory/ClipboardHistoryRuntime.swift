import Foundation
import AppKit
import KeyboardShortcuts

@MainActor
final class ClipboardHistoryRuntime {
    static let shared = ClipboardHistoryRuntime()

    let store: ClipboardHistoryStore?
    private let monitor: ClipboardMonitor?
    private(set) var cleanupTimer: Timer?
    private var didInstallHandlers = false
    private var didInstallLifecycleHooks = false
    private let defaults: UserDefaults
    private let now: () -> Date
    private let notificationCenter: NotificationCenter
    private let lockNotificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private var notificationTokens: [NSObjectProtocol] = []
    static let bootTimeKey = "clipboardHistorySystemBootTime"
    static let openShortcutNames: [KeyboardShortcuts.Name] = [.openClipboardHistory]

    nonisolated static func didSystemRestart(previousBootTime: TimeInterval?, currentBootTime: TimeInterval) -> Bool {
        guard let previousBootTime else { return false }
        return abs(previousBootTime - currentBootTime) > 3
    }

    nonisolated static func shouldClearDaily(now: Date, lastClear: Date?, time: Int, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let currentMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        guard currentMinutes >= min(1_439, max(0, time / 60)) else { return false }
        return lastClear.map { !calendar.isDate($0, inSameDayAs: now) } ?? true
    }

    nonisolated static func menuRecentItems(from items: [ClipboardItem]) -> [ClipboardItem] {
        Array(items.prefix(5))
    }

    private init() {
        defaults = .standard
        now = Date.init
        notificationCenter = .default
        lockNotificationCenter = DistributedNotificationCenter.default()
        workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        if let store = try? ClipboardHistoryStore() {
            self.store = store
            monitor = ClipboardMonitor(store: store)
        } else {
            store = nil
            monitor = nil
        }
    }

    init(
        store: ClipboardHistoryStore?,
        monitor: ClipboardMonitor?,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default,
        lockNotificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.store = store
        self.monitor = monitor
        self.defaults = defaults
        self.now = now
        self.notificationCenter = notificationCenter
        self.lockNotificationCenter = lockNotificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    func start() {
        monitor?.start()
        detectRestartAndStoreBootTime()
        installLifecycleHooks()
        installShortcutHandlers()
        startCleanupTimer()
    }

    func startCleanupTimer() {
        guard cleanupTimer == nil, store != nil else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.runScheduledCleanup() }
        }
    }

    func runScheduledCleanup() async {
        guard let store else { return }
        let currentTime = now()
        try? await store.cleanupExpired(now: currentTime)
        guard bool(ClipboardHistorySettings.Keys.clearDaily),
              Self.shouldClearDaily(
                now: currentTime,
                lastClear: defaults.object(forKey: ClipboardHistorySettings.Keys.lastDailyClear) as? Date,
                time: defaults.object(forKey: ClipboardHistorySettings.Keys.clearDailyTime) as? Int ?? 32_400
              ) else { return }
        await clearHistory(store: store)
        defaults.set(currentTime, forKey: ClipboardHistorySettings.Keys.lastDailyClear)
    }

    func clearForScreenLock() async {
        guard bool(ClipboardHistorySettings.Keys.clearOnLock), let store else { return }
        await clearHistory(store: store)
    }

    func clearForSleep() async {
        guard bool(ClipboardHistorySettings.Keys.clearOnSleep), let store else { return }
        await clearHistory(store: store)
    }

    private func clearHistory(store: ClipboardHistoryStore) async {
        try? await store.clear(
            includingPinned: true,
            keepingFavorites: bool(ClipboardHistorySettings.Keys.keepFavoritesOnClear, defaultValue: true),
            keepingTagged: bool(ClipboardHistorySettings.Keys.keepTaggedOnClear, defaultValue: true)
        )
    }

    private func bool(_ key: String, defaultValue: Bool = false) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    func togglePause() {
        guard let monitor else { return }
        if ClipboardHistorySettings.isPaused {
            monitor.resume()
        } else {
            monitor.pause()
        }
    }

    func pause(_ paused: Bool) {
        guard let monitor else { return }
        paused ? monitor.pause() : monitor.resume()
    }

    func exportArchive(to url: URL, password: String? = nil) async throws {
        guard let store else { throw ClipboardHistoryError.corruptStore }
        let entries = try await store.archiveEntries()
        try await Task.detached(priority: .utility) {
            try ClipboardHistoryArchive.write(entries, to: url, password: password)
        }.value
    }

    func importArchive(from url: URL, password: String? = nil) async throws {
        guard let store else { throw ClipboardHistoryError.corruptStore }
        let entries = try await Task.detached(priority: .utility) {
            try ClipboardHistoryArchive.read(from: url, password: password)
        }.value
        try await store.mergeArchiveEntries(entries)
    }

    func storageSize() async -> Int64 {
        guard let store else { return 0 }
        return (try? await store.storageSize()) ?? 0
    }

    func deleteItems(from bundleIdentifier: String) async {
        guard let store else { return }
        try? await store.deleteItems(from: bundleIdentifier)
    }

    func recordDictation(_ text: String) {
        guard let store else { return }
        Task { try? await store.recordDictation(text) }
    }

    /// Pastes the next item of the paste sequence; formatted keeps the original representations.
    func pasteNextClipboardItem(
        formatted: Bool,
        operation: ClipboardHistoryPasteOperation? = nil
    ) async -> ClipboardItem? {
        guard let store else { return nil }
        if formatted {
            return try? await store.pasteNextFormatted(operation: operation)
        }
        return try? await store.pasteNext(asPlainText: true, operation: operation)
    }

    private func detectRestartAndStoreBootTime() {
        let bootTime = now().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        let previousBootTime = defaults.object(forKey: Self.bootTimeKey) as? Double
        Task { await clearAfterRestartIfNeeded(previousBootTime: previousBootTime, currentBootTime: bootTime) }
        defaults.set(bootTime, forKey: Self.bootTimeKey)
    }

    @discardableResult
    func clearAfterRestartIfNeeded(previousBootTime: TimeInterval?, currentBootTime: TimeInterval) async -> Bool {
        guard Self.didSystemRestart(previousBootTime: previousBootTime, currentBootTime: currentBootTime),
              bool(ClipboardHistorySettings.Keys.clearOnRestart),
              let store else { return false }
        await clearHistory(store: store)
        return true
    }

    func installLifecycleHooks() {
        guard !didInstallLifecycleHooks else { return }
        didInstallLifecycleHooks = true
        let lifecycleDefaults = defaults
        notificationTokens.append(notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let store = self?.store else { return }
            let clearOnQuit = lifecycleDefaults.object(forKey: ClipboardHistorySettings.Keys.clearOnQuit) as? Bool ?? false
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                if clearOnQuit {
                    try? await store.clear(
                        includingPinned: true,
                        keepingFavorites: lifecycleDefaults.object(forKey: ClipboardHistorySettings.Keys.keepFavoritesOnClear) as? Bool ?? true,
                        keepingTagged: lifecycleDefaults.object(forKey: ClipboardHistorySettings.Keys.keepTaggedOnClear) as? Bool ?? true
                    )
                }
                // Index writes are debounced; persist the last ones before the process exits.
                try? await store.flushPendingWrites()
                finished.signal()
            }
            finished.wait()
        })
        notificationTokens.append(lockNotificationCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.clearForScreenLock() }
        })
        notificationTokens.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.clearForSleep() }
        })
    }

    private func installShortcutHandlers() {
        guard !didInstallHandlers else { return }
        didInstallHandlers = true
        for name in Self.openShortcutNames {
            KeyboardShortcuts.onKeyUp(for: name) {
                Task { @MainActor in ClipboardHistoryPanelEntry.show() }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pauseClipboardHistory) { [weak self] in
            self?.togglePause()
        }
        KeyboardShortcuts.onKeyUp(for: .pasteNextClipboardItem) { [weak self] in
            Task { await self?.pasteNextClipboardItem(formatted: false) }
        }
        KeyboardShortcuts.onKeyUp(for: .pasteNextClipboardItemFormatted) { [weak self] in
            Task { await self?.pasteNextClipboardItem(formatted: true) }
        }
    }
}
