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
    private static let bootTimeKey = "clipboardHistorySystemBootTime"
    static let openShortcutNames: [KeyboardShortcuts.Name] = [.openClipboardHistory]

    nonisolated static func didSystemRestart(previousBootTime: TimeInterval?, currentBootTime: TimeInterval) -> Bool {
        guard let previousBootTime else { return false }
        return abs(previousBootTime - currentBootTime) > 3
    }

    nonisolated static func menuRecentItems(from items: [ClipboardItem]) -> [ClipboardItem] {
        Array(items.prefix(5))
    }

    private init() {
        if let store = try? ClipboardHistoryStore() {
            self.store = store
            monitor = ClipboardMonitor(store: store)
        } else {
            store = nil
            monitor = nil
        }
    }

    init(store: ClipboardHistoryStore?, monitor: ClipboardMonitor?) {
        self.store = store
        self.monitor = monitor
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
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            guard let store = self?.store else { return }
            Task { try? await store.cleanupExpired() }
        }
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
        let defaults = UserDefaults.standard
        let bootTime = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        if Self.didSystemRestart(
            previousBootTime: defaults.object(forKey: Self.bootTimeKey) as? Double,
            currentBootTime: bootTime
        ),
           ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.clearOnRestart),
           let store {
            Task { try? await store.clear(includingPinned: true) }
        }
        defaults.set(bootTime, forKey: Self.bootTimeKey)
    }

    private func installLifecycleHooks() {
        guard !didInstallLifecycleHooks else { return }
        didInstallLifecycleHooks = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let store = self?.store else { return }
            let clearOnQuit = ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.clearOnQuit)
            let finished = DispatchSemaphore(value: 0)
            Task.detached {
                if clearOnQuit {
                    try? await store.clear(includingPinned: true)
                }
                // Index writes are debounced; persist the last ones before the process exits.
                try? await store.flushPendingWrites()
                finished.signal()
            }
            finished.wait()
        }
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
