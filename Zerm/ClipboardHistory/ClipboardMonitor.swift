import AppKit
import Foundation

/// Polls `NSPasteboard.general` because macOS provides no pasteboard change notification API.
/// A 0.4-second timer with 0.1-second tolerance keeps copies responsive without waking the app constantly.
@MainActor
final class ClipboardMonitor {
    private static var ignoredChangeCounts: Set<Int> = []
    private static var ignoresNextChange = false

    private let store: ClipboardHistoryStore
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var pauseUntil: Date?
    private var pauseNextCopy = false

    init(store: ClipboardHistoryStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func pause() {
        UserDefaults.standard.set(true, forKey: ClipboardHistorySettings.Keys.paused)
    }

    func resume() {
        UserDefaults.standard.set(false, forKey: ClipboardHistorySettings.Keys.paused)
        pauseUntil = nil
        pauseNextCopy = false
    }

    func pause(forMinutes minutes: Double) {
        ClipboardHistorySettings.isPaused = false
        pauseUntil = Date().addingTimeInterval(max(0, minutes) * 60)
    }

    /// Skips one clipboard change, then resumes capture.
    func pauseForNextCopy() {
        ClipboardHistorySettings.isPaused = false
        pauseNextCopy = true
    }

    static func noteZermWrite(changeCount: Int) {
        ignoredChangeCounts.insert(changeCount)
        if ignoredChangeCounts.count > 32 { ignoredChangeCounts.removeAll() }
    }

    static func ignoreNextClipboardChange() {
        ignoresNextChange = true
    }

    static func cancelIgnoringNextClipboardChange() {
        ignoresNextChange = false
    }

    func poll() {
        guard ClipboardHistorySettings.isEnabled else { return }
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount
        if Self.ignoresNextChange {
            Self.ignoresNextChange = false
            return
        }
        let isIgnoredWrite = Self.ignoredChangeCounts.remove(currentCount) != nil
        guard !isIgnoredWrite, !ClipboardHistorySettings.isPaused else { return }
        if let pauseUntil {
            if Date() < pauseUntil { return }
            self.pauseUntil = nil
        }
        if pauseNextCopy {
            pauseNextCopy = false
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appInfo = ClipboardSourceApp(
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName
        )
        let items = pasteboard.pasteboardItems ?? []
        let representations = items.enumerated().flatMap { index, item in
            item.types.compactMap { type -> ClipboardRepresentation? in
                guard let data = item.data(forType: type) else { return nil }
                return ClipboardRepresentation(itemIndex: index, type: type.rawValue, data: data)
            }
        }
        let pasteboardTypes = items.flatMap { $0.types.map(\.rawValue) }
        guard !ClipboardExclusionPolicy.excludes(
            types: pasteboardTypes,
            sourceBundleIdentifier: app.bundleIdentifier,
            excludedApps: ClipboardHistorySettings.excludedApps,
            ignoreConfidential: ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.ignoreConfidential),
            ignoreTransient: ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.ignoreTransient)
        ), let captured = ClipboardItem.capture(representations: representations, sourceApp: appInfo) else { return }
        Task {
            if (try? await store.capture(captured)) != nil {
                await MainActor.run { SoundManager.shared.playClipboardCopySound() }
            }
        }
    }
}
