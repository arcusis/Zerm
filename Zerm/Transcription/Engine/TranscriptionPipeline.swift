import Foundation
import AVFoundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → prompt-detect → AI enhance → save → paste → dismiss
@MainActor
class TranscriptionPipeline {
    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let promptDetectionService = PromptDetectionService()
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TranscriptionPipeline")

    var licenseViewModel: LicenseViewModel

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
        self.licenseViewModel = LicenseViewModel()
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - model: The transcription model to use.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - isRunStillValid: Returns false when a newer pipeline run has superseded this one.
    ///   - onCleanup: Called when cancellation is detected to release model resources.
    ///   - onDismiss: Called at the end to dismiss the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        model: any TranscriptionModel,
        session: TranscriptionSession?,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: @escaping () -> Bool,
        isRunStillValid: @escaping () -> Bool = { true },
        onCleanup: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void
    ) async {
        if shouldCancel() || !isRunStillValid() {
            await onCleanup()
            return
        }

        var finalPastedText: String?
        var promptDetectionResult: PromptDetectionService.PromptDetectionResult?
        // Set once the mode and the enhancement preconditions are known, and read again
        // after the paste, which happens outside this do/catch.
        var shouldRefineAfterPaste = false

        logger.notice("🔄 Starting transcription...")

        do {
            let transcriptionStart = Date()
            var text: String
            // Hard timeout: if transcription hasn't returned within 120 seconds the
            // model/provider is hung.  Cancel it so the app returns to .idle rather than
            // staying stuck in the "Transcribing…" state indefinitely. (VoiceInk #338)
            text = try await withTranscriptionTimeout(seconds: 120) { [serviceRegistry = self.serviceRegistry] in
                if let session {
                    return try await session.transcribe(audioURL: audioURL)
                } else {
                    return try await serviceRegistry.transcribe(audioURL: audioURL, model: model)
                }
            }
            // If this run was superseded while awaiting transcription, drop the result.
            if !isRunStillValid() {
                logger.notice("⏹️ Transcription superseded by newer run — discarding")
                modelContext.delete(transcription)
                try? modelContext.save()
                await onCleanup()
                return
            }
            logger.notice("📝 Transcript: \(text.count, privacy: .public) characters")
            text = TranscriptionOutputFilter.filter(text)
            logger.notice("📝 Output filter result: \(text.count, privacy: .public) characters")
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            let powerModeManager = PowerModeManager.shared
            let activePowerModeConfig = powerModeManager.currentActiveConfiguration
            let powerModeName = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.name : nil
            let powerModeEmoji = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.emoji : nil

            if shouldCancel() { await onCleanup(); return }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled") {
                text = WhisperTextFormatter.format(text)
                logger.notice("📝 Formatted transcript: \(text.count, privacy: .public) characters")
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            logger.notice("📝 WordReplacement: \(text.count, privacy: .public) characters")

            // Offline dictation commands ("new line", "scratch that", spoken punctuation)
            // run as a deterministic post-processor so they work without the LLM prompt.
            text = DictationCommandProcessor.process(text)

            let cleanedText = TranscriptionOutputFilter.applyUserCleanupPreferences(text)
            logger.notice("📝 Cleanup preferences result: \(cleanedText.count, privacy: .public) characters")
            let audioAsset = AVURLAsset(url: audioURL)
            let actualDuration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0

            DebugLogger.shared.log(
                "TranscriptionPipeline",
                "transcription finished: chars=\(cleanedText.count) empty=\(cleanedText.isEmpty) model=\(model.displayName) provider=\(model.provider.rawValue) dur=\(String(format: "%.2f", actualDuration))s"
            )

            // Notify the user when the transcription returns nothing — typically a very
            // short phrase released before the model captures enough audio, or a fully
            // silent recording. Without feedback the user sees no paste and no error,
            // which is confusing. (VoiceInk #686)
            if cleanedText.isEmpty {
                logger.notice("⚠️ Transcription returned empty result model=\(model.displayName, privacy: .public) dur=\(actualDuration, privacy: .public)s")
                let shortClip = actualDuration < 0.8
                let title = shortClip
                    ? "Nothing transcribed — hold a bit longer before releasing"
                    : "Nothing transcribed — try again or switch model in AI Models"
                await MainActor.run {
                    if shortClip {
                        NotificationManager.shared.showNotification(
                            title: title,
                            type: .warning,
                            duration: 4.0
                        )
                    } else {
                        NotificationManager.shared.showNotification(
                            title: title,
                            type: .warning,
                            duration: 4.0,
                            actionButton: (label: "Open Models", action: {
                                MenuBarManager.shared?.openMainWindowAndNavigate(to: "Dictation Models")
                            })
                        )
                    }
                }
            }

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.powerModeName = powerModeName
            transcription.powerModeEmoji = powerModeEmoji
            finalPastedText = cleanedText

            let autoSendKey = activePowerModeConfig?.autoSendKey
            // Auto-send submits the field about half a second after the paste, so there is
            // nothing left to refine afterwards. Where both are configured the only
            // coherent outcome is to enhance first and send the enhanced text, so this
            // falls back to Enhanced rather than silently dropping the enhancement.
            let outputMode: DictationOutputMode = {
                let configured = DictationOutputMode.current
                guard configured == .instantRefine, autoSendKey?.isEnabled == true else { return configured }
                return .enhanced
            }()
            let blocksOnEnhancement = outputMode == .enhanced
            let allowPromptTriggeredEnhancement = UserDefaults.standard.bool(forKey: "AllowPromptTriggeredEnhancement")

            if blocksOnEnhancement,
               allowPromptTriggeredEnhancement,
               let enhancementService,
               enhancementService.isConfigured {
                let detectionResult = await promptDetectionService.analyzeText(text, with: enhancementService)
                promptDetectionResult = detectionResult
                await promptDetectionService.applyDetectionResult(detectionResult, to: enhancementService)
            }

            let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
            let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
            let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
            let shouldSkipEnhancement = isSkipShortEnhancementEnabled && WordCounter.count(in: text) <= shortEnhancementWordThreshold && !(promptDetectionResult?.shouldEnableAI == true)

            let canEnhance = enhancementService?.isEnhancementEnabled == true
                && enhancementService?.isConfigured == true
                && !shouldSkipEnhancement
            shouldRefineAfterPaste = outputMode == .instantRefine && canEnhance

            if let enhancementService,
               blocksOnEnhancement,
               canEnhance {
                if shouldCancel() { await onCleanup(); return }

                onStateChange(.enhancing)
                let textForAI = promptDetectionResult?.processedText ?? text

                do {
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                        textForAI,
                        isCancelled: { shouldCancel() }
                    )
                    logger.notice("📝 AI enhancement: \(enhancedText.count, privacy: .public) characters")
                    transcription.enhancedText = enhancedText
                    transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                    transcription.promptName = promptName
                    transcription.enhancementDuration = enhancementDuration
                    transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                    transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                    // An empty enhancement must never replace a good transcript. The on-device
                    // path can return "" without throwing (a failed llama_decode breaks out of
                    // the token loop and still yields a valid empty string), which silently
                    // pasted nothing at all — worst on long dictations, where losing the text
                    // hurts most. Fall back to the raw transcript for every provider.
                    if enhancedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        logger.error("AI enhancement returned empty text — pasting the raw transcript instead")
                    } else {
                        finalPastedText = enhancedText
                    }
                } catch {
                    // A cancelled enhancement is not a failure — let it propagate to
                    // the outer cancellation handler instead of relabelling it.
                    if error is CancellationError { throw error }
                    let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    transcription.enhancedText = "Enhancement failed: \(errorDescription)"
                    let shortReason = String(errorDescription.prefix(80))
                    await MainActor.run {
                        NotificationManager.shared.showNotification(
                            title: "Enhancement failed: \(shortReason)",
                            type: .warning
                        )
                    }
                    if shouldCancel() { await onCleanup(); return }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue

        } catch is CancellationError {
            // The pipeline task was cancelled — e.g. a new recording started, the
            // engine was torn down, or the user toggled again mid-transcription.
            // This is normal control flow, NOT a failure: a raw CancellationError
            // surfaces as the confusing "The operation couldn't be completed.
            // (Swift.CancellationError error 1.)".  Discard the empty pending record
            // and bail out quietly instead of writing a "Transcription Failed" entry.
            logger.notice("⏹️ Transcription cancelled — discarding pending record")
            modelContext.delete(transcription)
            try? modelContext.save()
            await onCleanup()
            return
        } catch {
            // A late/transitive cancellation can arrive wrapped or after the task is
            // already cancelled; treat that as a cancel too rather than a hard failure.
            if Task.isCancelled {
                logger.notice("⏹️ Transcription cancelled (task) — discarding pending record")
                modelContext.delete(transcription)
                try? modelContext.save()
                await onCleanup()
                return
            }
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let recoverySuggestion = (error as? LocalizedError)?.recoverySuggestion ?? ""
            let fullErrorText = recoverySuggestion.isEmpty ? errorDescription : "\(errorDescription) \(recoverySuggestion)"

            transcription.text = "Transcription Failed: \(fullErrorText)"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            finalPastedText = nil
            let shortReason = String(fullErrorText.prefix(100))
            await MainActor.run {
                NotificationManager.shared.showNotification(
                    title: "Transcription failed: \(shortReason)",
                    type: .error,
                    duration: 5.0
                )
            }
            logger.error("❌ Transcription failed: \(fullErrorText, privacy: .public)")
            DebugLogger.shared.log("TranscriptionPipeline", "transcription failed: \(shortReason)")
        }

        try? modelContext.save()

        // Recorded to the separate usage store, which transcript retention never touches.
        // Without this the Dashboard is only ever a view of whatever history has not been
        // auto-deleted yet, which is why it appeared to reset itself.
        if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            UsageStatsService.shared.record(transcription)
        }

        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

        if shouldCancel() || !isRunStillValid() { await onCleanup(); return }

        // Never paste if a newer recording/pipeline already started.
        if let textToPaste = finalPastedText,
           transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue,
           isRunStillValid() {
            let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
            let pastedText = textToPaste + (appendSpace ? " " : "")

            var anchorSnapshot: AXTextAnchorCapture.PrePasteSnapshot?
            if shouldRefineAfterPaste {
                anchorSnapshot = await CursorPaster.pasteAtCursorCapturingAnchor(pastedText).snapshot
            } else {
                _ = await CursorPaster.startPasteAtCursor(pastedText).value
            }

            let autoSendKey = PowerModeManager.shared.currentActiveConfiguration?.autoSendKey
            SoundManager.shared.playStopSound()

            // Hand off before the recorder dismisses. Refinement runs entirely after this
            // point and never blocks the pipeline, so the pill goes away exactly as it
            // does in Instant mode.
            if shouldRefineAfterPaste, let enhancementService {
                RefineInPlaceCoordinator.shared.start(
                    snapshot: anchorSnapshot,
                    pastedText: pastedText,
                    transcription: transcription,
                    modelContext: modelContext,
                    enhancementService: enhancementService,
                    isSuperseded: { !isRunStillValid() }
                )
            }
            if let autoSendKey, autoSendKey.isEnabled {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    CursorPaster.performAutoSend(autoSendKey)
                }
            }
        }

        if let result = promptDetectionResult,
           let enhancementService,
           result.shouldEnableAI {
            await promptDetectionService.restoreOriginalSettings(result, to: enhancementService)
        }

        if isRunStillValid() {
            await onDismiss()
        } else {
            await onCleanup()
        }
    }
}

// MARK: - Transcription timeout helper

private struct TranscriptionTimeoutError: LocalizedError {
    var errorDescription: String? { "Transcription timed out. The model may be unresponsive — please try again." }
    var recoverySuggestion: String? { "If this keeps happening, try reloading the model in Settings." }
}

/// Runs `operation` and throws `TranscriptionTimeoutError` if it has not returned
/// within `seconds`.  The operation task is cancelled on timeout.
private func withTranscriptionTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TranscriptionTimeoutError()
        }
        // First to finish wins; the other is cancelled immediately.
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
