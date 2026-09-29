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
    private var copyMergeEventMonitor: Any?
    private var copyMergeWasEnabled = false
    private var lastCommandCopyAt: Date?
    private var copyMergeAwaitingClipboard = false

    init(store: ClipboardHistoryStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        refreshCopyMergeMonitor()
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
        if let copyMergeEventMonitor { NSEvent.removeMonitor(copyMergeEventMonitor) }
        copyMergeEventMonitor = nil
        copyMergeWasEnabled = false
        lastCommandCopyAt = nil
        copyMergeAwaitingClipboard = false
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
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount
        refreshCopyMergeMonitor()
        guard ClipboardHistorySettings.isEnabled else { return }
        let shouldMergeCopy = copyMergeAwaitingClipboard
        copyMergeAwaitingClipboard = false
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
        ), !representations.isEmpty else { return }
        let now = Date()
        let shouldMerge = shouldMergeCopy
        Task.detached(priority: .userInitiated) { [store] in
            guard let captured = ClipboardItem.capture(
                representations: representations,
                sourceApp: appInfo,
                createdAt: now
            ) else { return }
            let text = captured.kind == .plainText
                ? ClipboardPanelText.plainText(from: captured.representations, fallback: captured.preview) : nil
            do {
                if shouldMerge, let text {
                    guard await store.shouldCapture(captured.kind) else { return }
                    if let merged = try await store.appendCopyToPreviousText(text, separator: ClipboardHistoryEngineSettings.copyMergeSeparator) {
                        if ClipboardHistoryEngineSettings.copyMergeUpdatesClipboard {
                            let payload = try await store.itemWithPayload(merged.id)
                            let mergedText = ClipboardPanelText.plainText(from: payload.representations, fallback: payload.preview)
                            await MainActor.run { [weak self] in
                                guard let self, self.pasteboard.changeCount == currentCount else { return }
                                if ClipboardManager.setClipboard(mergedText, on: self.pasteboard) {
                                    Self.noteZermWrite(changeCount: self.pasteboard.changeCount)
                                }
                            }
                        }
                        return
                    }
                }
                _ = try await store.capture(captured, now: now)
                await MainActor.run { SoundManager.shared.playClipboardCopySound() }
            } catch { }
        }
    }

    private func refreshCopyMergeMonitor() {
        let enabled = ClipboardHistoryEngineSettings.copyMergeEnabled
        guard enabled != copyMergeWasEnabled else { return }
        copyMergeWasEnabled = enabled
        if enabled {
            copyMergeEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" else { return }
                Task { @MainActor in
                    guard let self else { return }
                    let now = Date()
                    if let prior = self.lastCommandCopyAt, now.timeIntervalSince(prior) <= 0.8 {
                        self.copyMergeAwaitingClipboard = true
                    }
                    self.lastCommandCopyAt = now
                }
            }
        } else {
            if let copyMergeEventMonitor { NSEvent.removeMonitor(copyMergeEventMonitor) }
            copyMergeEventMonitor = nil
            lastCommandCopyAt = nil
            copyMergeAwaitingClipboard = false
        }
    }
}
