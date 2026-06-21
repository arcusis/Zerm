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
    ///   - onCleanup: Called when cancellation is detected to release model resources.
    ///   - onDismiss: Called at the end to dismiss the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        model: any TranscriptionModel,
        session: TranscriptionSession?,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onCleanup: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void
    ) async {
        if shouldCancel() {
            await onCleanup()
            return
        }

        var finalPastedText: String?
        var promptDetectionResult: PromptDetectionService.PromptDetectionResult?

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
            logger.notice("📝 Transcript: \(text, privacy: .public)")
            text = TranscriptionOutputFilter.filter(text)
            logger.notice("📝 Output filter result: \(text, privacy: .public)")
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            let powerModeManager = PowerModeManager.shared
            let activePowerModeConfig = powerModeManager.currentActiveConfiguration
            let powerModeName = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.name : nil
            let powerModeEmoji = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.emoji : nil

            if shouldCancel() { await onCleanup(); return }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled") {
                text = WhisperTextFormatter.format(text)
                logger.notice("📝 Formatted transcript: \(text, privacy: .public)")
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            logger.notice("📝 WordReplacement: \(text, privacy: .public)")

            let cleanedText = TranscriptionOutputFilter.applyUserCleanupPreferences(text)
            logger.notice("📝 Cleanup preferences result: \(cleanedText, privacy: .public)")

            // Notify the user when the transcription returns nothing — typically a very
            // short phrase released before the model captures enough audio, or a fully
            // silent recording. Without feedback the user sees no paste and no error,
            // which is confusing. (VoiceInk #686)
            if cleanedText.isEmpty {
                logger.notice("⚠️ Transcription returned empty result")
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: "Nothing transcribed — audio too short or silent",
                        type: .warning,
                        duration: 3.0
                    )
                }
            }

            let audioAsset = AVURLAsset(url: audioURL)
            let actualDuration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.powerModeName = powerModeName
            transcription.powerModeEmoji = powerModeEmoji
            finalPastedText = cleanedText

            let instantTranscriptionMode = UserDefaults.standard.bool(forKey: "InstantTranscriptionMode")
            let allowPromptTriggeredEnhancement = UserDefaults.standard.bool(forKey: "AllowPromptTriggeredEnhancement")

            if !instantTranscriptionMode,
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

            if let enhancementService,
               !instantTranscriptionMode,
               enhancementService.isEnhancementEnabled,
               enhancementService.isConfigured,
               !shouldSkipEnhancement {
                if shouldCancel() { await onCleanup(); return }

                onStateChange(.enhancing)
                let textForAI = promptDetectionResult?.processedText ?? text

                do {
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(textForAI)
                    logger.notice("📝 AI enhancement: \(enhancedText, privacy: .public)")
                    transcription.enhancedText = enhancedText
                    transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                    transcription.promptName = promptName
                    transcription.enhancementDuration = enhancementDuration
                    transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                    transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                    finalPastedText = enhancedText
                } catch {
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

        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let recoverySuggestion = (error as? LocalizedError)?.recoverySuggestion ?? ""
            let fullErrorText = recoverySuggestion.isEmpty ? errorDescription : "\(errorDescription) \(recoverySuggestion)"

            transcription.text = "Transcription Failed: \(fullErrorText)"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        try? modelContext.save()
        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

        if shouldCancel() { await onCleanup(); return }

        if let textToPaste = finalPastedText,
           transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
            let pastedText = textToPaste + (appendSpace ? " " : "")
            _ = await CursorPaster.startPasteAtCursor(pastedText).value
            let autoSendKey = PowerModeManager.shared.currentActiveConfiguration?.autoSendKey
            SoundManager.shared.playStopSound()
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

        await onDismiss()
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
