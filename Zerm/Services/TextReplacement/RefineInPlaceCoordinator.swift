import Foundation
import AppKit
import ApplicationServices
import SwiftData
import os

/// Runs AI enhancement *after* the raw transcript has already been pasted, then swaps the
/// two over in place if — and only if — that can be done without disturbing anything the
/// user has done since.
///
/// Structurally this mirrors `AutoLearnVocabularyService`: capture an element, watch it
/// for value changes, bail the moment the user switches apps, and give up on a timer.
@MainActor
final class RefineInPlaceCoordinator {
    static let shared = RefineInPlaceCoordinator()

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "RefineInPlace")

    /// Hard ceiling on a single refine, independent of the enhancement timeout, so no
    /// observer or task can outlive the moment the result stops being useful.
    private static let hardDeadline: TimeInterval = 10

    /// Set by `ZermEngine`. Read Aloud and refine both queue on the same on-device model
    /// actor, and Read Aloud is something the user just asked for, so refine yields.
    var shouldYield: (() -> Bool)?

    private(set) var isRefining = false

    private var task: Task<Void, Never>?
    private var axObserver: AXObserver?
    private var workspaceObserver: NSObjectProtocol?
    private var targetWasEdited = false
    private var appWasSwitched = false

    private init() {}

    func cancel() {
        task?.cancel()
        task = nil
        teardownObservers()
        isRefining = false
    }

    /// - Parameters:
    ///   - snapshot: Focused-element reading taken just before the paste, or nil when the
    ///     target exposes no usable accessibility text — refine still runs, it just goes
    ///     straight to the fallback.
    ///   - pastedText: Exactly what was pasted, trailing space included.
    ///   - isSuperseded: True once a newer recording has started. A stale refine writing
    ///     into a field that now holds a *newer* transcript would be the worst outcome
    ///     this whole design can produce, so it is checked at every step.
    func start(
        snapshot: AXTextAnchorCapture.PrePasteSnapshot?,
        pastedText: String,
        transcription: Transcription,
        modelContext: ModelContext,
        enhancementService: AIEnhancementService,
        isSuperseded: @escaping () -> Bool
    ) {
        cancel()

        isRefining = true
        targetWasEdited = false
        appWasSwitched = false

        let recordID = transcription.persistentModelID
        let started = Date()
        // Read now, not when the request goes out: dismissing the recorder ends the Power
        // Mode session and restores the global prompt selection, which would otherwise
        // land mid-refine.
        let promptID = enhancementService.selectedPromptId

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.teardownObservers()
                self.isRefining = false
            }

            var anchor: AXTextAnchor?
            if let snapshot {
                anchor = await AXTextAnchorCapture.confirm(snapshot, pastedText: pastedText)
                if let anchor {
                    self.observe(anchor)
                }
            }

            guard !Task.isCancelled, !isSuperseded() else { return }

            let enhanced: String
            let duration: TimeInterval
            let promptName: String?
            do {
                (enhanced, duration, promptName) = try await enhancementService.enhance(
                    pastedText.trimmingCharacters(in: .whitespacesAndNewlines),
                    isCancelled: { [weak self] in
                        Task.isCancelled
                            || isSuperseded()
                            || (self?.shouldYield?() ?? false)
                            || Date().timeIntervalSince(started) > Self.hardDeadline
                    },
                    contextPolicy: .minimal,
                    usingPrompt: promptID
                )
            } catch is CancellationError {
                return
            } catch {
                self.logger.notice("Refine did not complete: \(error.localizedDescription, privacy: .public)")
                return
            }

            guard !Task.isCancelled, !isSuperseded() else { return }
            guard Date().timeIntervalSince(started) <= Self.hardDeadline else {
                self.logger.notice("Refine finished past its deadline — discarding")
                return
            }

            // Persist regardless of whether the swap happens. This is lossless and free,
            // and it is what makes History and the "paste last enhancement" shortcut work
            // even in apps that can never be written to.
            self.persist(
                enhanced: enhanced,
                duration: duration,
                promptName: promptName,
                recordID: recordID,
                modelContext: modelContext,
                enhancementService: enhancementService
            )

            await self.apply(enhanced: enhanced, anchor: anchor)
        }
    }

    // MARK: - Applying

    private func apply(enhanced: String, anchor: AXTextAnchor?) async {
        guard let anchor else { return offerWithoutReplacing(enhanced) }
        guard !targetWasEdited, !appWasSwitched else {
            logger.notice("Target changed during refine — leaving the pasted text alone")
            return offerWithoutReplacing(enhanced)
        }
        // The frontmost-app check has to be read here, on the main actor, before handing
        // the rest off.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPID == anchor.pid else {
            logger.notice("Refine declined: appChanged")
            return offerWithoutReplacing(enhanced)
        }

        let strategy = await TargetAppCapabilities.shared.verdict(for: anchor)

        // Clipboard-paste replacement is a second copy. Instant + Refine may only
        // rewrite through a direct accessibility write; everything else leaves the
        // raw paste alone.
        guard strategy == .directAccessibility else {
            logger.notice("Refine declined: \(String(describing: strategy), privacy: .public)")
            return offerWithoutReplacing(enhanced)
        }

        // Gate checks and the write are both synchronous IPC into the target process.
        // Bounded by the 150 ms messaging timeout, but that is still far too long to spend
        // on the main thread, so the whole exchange happens off it.
        let outcome = await Task.detached(priority: .userInitiated) { () -> Refusal? in
            if let refusal = AXTextReplacer.canReplace(anchor, with: enhanced) { return refusal }
            return AXTextReplacer.replace(anchor, with: enhanced) ? nil : .writeFailed
        }.value

        guard let outcome else { return }
        logger.notice("Refine declined: \(outcome.rawValue, privacy: .public)")
        // Identical text is not a failure and needs no notification.
        guard outcome != .nothingToDo else { return }
        offerWithoutReplacing(enhanced)
    }

    private typealias Refusal = AXTextReplacer.Refusal

    /// The fallback for terminals, secure fields, changed targets, and editors that expose no
    /// exact settable text range. The
    /// refined text is never put on the clipboard without being asked for — silently
    /// replacing the user's clipboard is exactly the surprise `restoreClipboardAfterPaste`
    /// exists to avoid.
    private func offerWithoutReplacing(_ enhanced: String) {
        NotificationManager.shared.showNotification(
            title: String(localized: "Zerm kept the original text to avoid editing the wrong content."),
            type: .warning,
            duration: 6.0,
            actionButton: (label: String(localized: "Copy Refined Text"), action: {
                _ = ClipboardManager.copyToClipboard(enhanced)
            })
        )
    }

    private func persist(
        enhanced: String,
        duration: TimeInterval,
        promptName: String?,
        recordID: PersistentIdentifier,
        modelContext: ModelContext,
        enhancementService: AIEnhancementService
    ) {
        // The record can have been deleted by a cancellation path while we were away.
        guard let record = modelContext.model(for: recordID) as? Transcription else { return }
        record.enhancedText = enhanced
        record.enhancementDuration = duration
        record.promptName = promptName
        record.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
        record.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
        record.aiRequestUserMessage = enhancementService.lastUserMessageSent
        try? modelContext.save()

        UsageStatsService.shared.recordDeferredEnhancement(seconds: duration)
    }

    // MARK: - Observers

    private func observe(_ anchor: AXTextAnchor) {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWasSwitched = true }
        }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let coordinator = Unmanaged<RefineInPlaceCoordinator>.fromOpaque(refcon).takeUnretainedValue()
            // Accessibility observer sources are attached to the main run loop below, so
            // this callback is already running on the main actor.
            MainActor.assumeIsolated { coordinator.targetWasEdited = true }
        }

        guard AXObserverCreate(anchor.pid, callback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            observer,
            anchor.element,
            kAXValueChangedNotification as CFString,
            refcon
        ) == .success else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    private func teardownObservers() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
            self.axObserver = nil
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }
}
