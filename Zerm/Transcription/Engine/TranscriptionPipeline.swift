import Foundation
import AVFoundation
import SwiftData
import os

/// Handles the full post-recording pipeline, in this order:
///
/// 1. transcribe, with the recording's model and language
/// 2. deterministic cleanup — output filter and fillers, formatting, word replacement, dictation
///    commands ("new line", "scratch that")
/// 3. the user's lowercase and punctuation preferences → the text pasted by Instant modes
/// 4. enhancement of the cleaned text from step 2, identical for Enhanced and Instant + Refine
/// 5. step 3's preferences again, on the enhancement → the text Enhanced pastes or Refine writes
/// 6. save → paste → hand refine off → dismiss
///
/// Prompts must not repeat step 2: a model asked to remove fillers or "scratch that" a second time
/// only gets another chance to damage the text.
@MainActor
class TranscriptionPipeline {
    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TranscriptionPipeline")

    /// How long Enhanced output waits for on-screen text still being read.
    static let screenContextWaitLimit: TimeInterval = 1

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
    ///   - dictationSession: The configuration resolved when recording started.
    ///   - transcriptionSession: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - isRunStillValid: Returns false when a newer pipeline run has superseded this one.
    ///   - onCleanup: Called when cancellation is detected to release model resources.
    ///   - onDismiss: Called at the end to dismiss the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        dictationSession: DictationSessionConfiguration,
        transcriptionSession: TranscriptionSession?,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: @escaping @MainActor @Sendable () -> Bool,
        isRunStillValid: @escaping @MainActor @Sendable () -> Bool = { true },
        onCleanup: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void
    ) async {
        if shouldCancel() || !isRunStillValid() {
            markPreservedFailure(
                transcription,
                message: String(localized: "Recording saved — transcription was cancelled. Retry from History.")
            )
            await onCleanup()
            return
        }

        let model = dictationSession.transcriptionModel
        var finalPastedText: String?
        // Built before the paste and the recorder's dismissal, so nothing a dismissal resets can
        // reach it. Read again after the paste, which happens outside this do/catch.
        var refineRequest: EnhancementRequest?

        logger.notice("🔄 Starting transcription...")

        do {
            let transcriptionStart = Date()
            // Hard timeout: if transcription hasn't returned within 120 seconds the
            // model/provider is hung.  Cancel it so the app returns to .idle rather than
            // staying stuck in the "Transcribing…" state indefinitely. (VoiceInk #338)
            let transcript = try await LanguagePreference.$operationOverrideCode.withValue(dictationSession.languageCode) {
                try await withTranscriptionTimeout(seconds: 120) { [serviceRegistry = self.serviceRegistry] in
                    if let transcriptionSession {
                        return try await transcriptionSession.transcribe(audioURL: audioURL)
                    } else {
                        return try await serviceRegistry.transcribe(audioURL: audioURL, model: model)
                    }
                }
            }
            // If this run was superseded while awaiting transcription, drop the result.
            if !isRunStillValid() {
                logger.notice("⏹️ Transcription superseded by newer run — keeping audio")
                markPreservedFailure(
                    transcription,
                    message: String(localized: "Recording saved — a newer take started before this one finished. Retry from History.")
                )
                await onCleanup()
                return
            }
            logger.notice("📝 Transcript: \(transcript.count, privacy: .public) characters")
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            let textCleanup = dictationSession.textCleanup
            let cleanedText = DictationTextProcessing.clean(transcript, formatsText: textCleanup.formatsText) { [modelContext] text in
                WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            }
            let pastedText = textCleanup.applyPreferences(to: cleanedText)
            logger.notice("📝 Cleaned transcript: \(pastedText.count, privacy: .public) characters")
            let audioAsset = AVURLAsset(url: audioURL)
            let actualDuration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0

            DebugLogger.shared.log(
                "TranscriptionPipeline",
                "transcription finished: chars=\(pastedText.count) empty=\(pastedText.isEmpty) model=\(model.displayName) provider=\(model.provider.rawValue) dur=\(String(format: "%.2f", actualDuration))s"
            )

            // Notify the user when the transcription returns nothing — typically a very
            // short phrase released before the model captures enough audio, or a fully
            // silent recording. Without feedback the user sees no paste and no error,
            // which is confusing. (VoiceInk #686)
            if pastedText.isEmpty {
                logger.notice("⚠️ Transcription returned empty result model=\(model.displayName, privacy: .public) dur=\(actualDuration, privacy: .public)s")
                let shortClip = actualDuration < 0.8
                let title = shortClip
                    ? String(localized: "Nothing transcribed — hold a bit longer before releasing")
                    : String(localized: "Nothing transcribed — try again or switch model in AI Models")
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
                        actionButton: (label: String(localized: "Open Models"), action: {
                            MenuBarManager.shared?.openMainWindowAndNavigate(to: "Dictation Models")
                        })
                    )
                }
            }

            transcription.text = pastedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.powerModeName = dictationSession.powerMode?.name
            transcription.powerModeEmoji = dictationSession.powerMode?.emoji
            finalPastedText = pastedText

            if let enhancementService, !pastedText.isEmpty {
                let configuredMode = dictationSession.configuredOutputMode(global: enhancementService.outputMode)
                let plan = enhancementService.plan(
                    for: cleanedText,
                    configuredMode: configuredMode,
                    autoSendEnabled: dictationSession.autoSendEnabled,
                    overrides: dictationSession.enhancementOverrides
                )
                // Auto-send submits the field about half a second after the paste, so there is
                // nothing left to refine afterwards: that case waits and pastes once.
                if configuredMode == .instantRefine, plan.outputMode == .enhanced {
                    logger.notice("Instant + Refine will wait and paste once because auto-send would submit the raw field")
                }

                if plan.outputMode.usesEnhancement, !plan.input.isEmpty {
                    if plan.skipsAsShort {
                        transcription.record(.skipped(.shortTranscription), of: nil)
                    } else {
                        var screenContext: String?
                        if plan.outputMode == .enhanced,
                           dictationSession.usesScreenContext(global: enhancementService.useScreenCaptureContext),
                           let capture = dictationSession.screenContext {
                            // The capture started with the recording and is usually done. If OCR
                            // is still running, enhance without it rather than make the paste wait.
                            screenContext = await BoundedWait.value(
                                of: capture,
                                within: Self.screenContextWaitLimit,
                                isCancelled: shouldCancel
                            ) ?? nil
                        }
                        if shouldCancel() { throw CancellationError() }
                        switch enhancementService.makeRequest(
                            input: plan.input,
                            purpose: plan.outputMode == .enhanced ? .enhanced : .refine,
                            overrides: plan.overrides,
                            clipboardContext: dictationSession.clipboardContext,
                            screenContext: screenContext
                        ) {
                        case .failure(let reason):
                            let outcome = EnhancementOutcome.skipped(.notConfigured(reason))
                            logger.notice("Enhancement skipped: \(outcome.recordReason ?? "", privacy: .public)")
                            transcription.record(outcome, of: nil)
                            EnhancementNotifier.shared.report(outcome, purpose: .enhanced)
                        case .success(let request) where plan.outputMode == .enhanced:
                            if !shouldCancel() {
                                onStateChange(.enhancing)
                            }
                            let outcome = await enhancementService.perform(request, isCancelled: shouldCancel)
                            // A cancelled enhancement is not a failure — let it propagate to the
                            // outer cancellation handler instead of relabelling it.
                            if outcome == .cancelled { throw CancellationError() }
                            transcription.record(outcome, of: request, finalize: textCleanup.applyPreferences(to:))
                            if case .enhanced = outcome, let enhancedText = transcription.enhancedText {
                                logger.notice("📝 AI enhancement: \(enhancedText.count, privacy: .public) characters")
                                finalPastedText = enhancedText
                            }
                            EnhancementNotifier.shared.report(outcome, purpose: .enhanced)
                        case .success(let request):
                            refineRequest = request
                        }
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue

        } catch is CancellationError {
            logger.notice("⏹️ Transcription cancelled — keeping audio for retry")
            markPreservedFailure(
                transcription,
                message: Self.describeTranscriptionFailure(CancellationError())
            )
            finalPastedText = nil
        } catch {
            let errorDescription = Self.describeTranscriptionFailure(error)
            let recoverySuggestion = (error as? LocalizedError)?.recoverySuggestion ?? ""
            let fullErrorText = recoverySuggestion.isEmpty ? errorDescription : "\(errorDescription) \(recoverySuggestion)"

            markPreservedFailure(transcription, message: String(localized: "Transcription Failed: \(fullErrorText)"))
            finalPastedText = nil
            let shortReason = String(fullErrorText.prefix(100))
            NotificationManager.shared.showNotification(
                title: String(localized: "Transcription failed: \(shortReason)"),
                type: .error,
                duration: 5.0
            )
            logger.error("❌ Transcription failed: \(fullErrorText, privacy: .public)")
            DebugLogger.shared.log("TranscriptionPipeline", "transcription failed: \(shortReason)")
        }

        let didPersist: Bool
        do {
            try modelContext.save()
            didPersist = true
        } catch {
            didPersist = false
            logger.error("Transcription finished but could not be persisted: \(error.localizedDescription, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: String(localized: "Transcription history could not be saved"),
                type: .error,
                duration: 5.0
            )
        }

        // Recorded to the separate usage store, which transcript retention never touches.
        // Without this the Dashboard is only ever a view of whatever history has not been
        // auto-deleted yet, which is why it appeared to reset itself.
        if didPersist,
           transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            UsageStatsService.shared.record(transcription)
        }

        // Completion means durable history, not merely an in-memory model mutation. The paste
        // below still proceeds so a transient disk failure never discards the user's words.
        if didPersist {
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
        }

        if shouldCancel() || !isRunStillValid() { await onCleanup(); return }

        // Never paste if a newer recording/pipeline already started.
        if let textToPaste = finalPastedText,
           transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue,
           isRunStillValid() {
            let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
            let pastedText = textToPaste + (appendSpace ? " " : "")

            var anchorSnapshot: AXTextAnchorCapture.PrePasteSnapshot?
            if refineRequest != nil {
                anchorSnapshot = await CursorPaster.pasteAtCursorCapturingAnchor(pastedText).snapshot
            } else {
                _ = await CursorPaster.startPasteAtCursor(pastedText).value
            }

            SoundManager.shared.playStopSound()

            // Hand off before the recorder dismisses. Refinement runs entirely after this
            // point and never blocks the pipeline, so the pill goes away exactly as it
            // does in Instant mode.
            if let refineRequest, let enhancementService {
                RefineInPlaceCoordinator.shared.start(
                    snapshot: anchorSnapshot,
                    pastedText: pastedText,
                    request: refineRequest,
                    textCleanup: dictationSession.textCleanup,
                    transcription: transcription,
                    modelContext: modelContext,
                    enhancementService: enhancementService,
                    isSuperseded: { !isRunStillValid() }
                )
            }
            if let autoSendKey = dictationSession.powerMode?.autoSendKey, autoSendKey.isEnabled {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    CursorPaster.performAutoSend(autoSendKey)
                }
            }
        }

        if isRunStillValid() {
            await onDismiss()
        } else {
            await onCleanup()
        }
    }

    private func markPreservedFailure(_ transcription: Transcription, message: String) {
        // English as well, for failures stored before the message was localized.
        if transcription.text.isEmpty
            || transcription.text.hasPrefix("Transcription Failed")
            || transcription.text.hasPrefix(String(localized: "Transcription Failed")) {
            transcription.text = message
        }
        transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        if transcription.duration <= 0,
           let urlString = transcription.audioFileURL,
           let url = URL(string: urlString),
           let duration = RecordingAudioStore.inspect(url)?.duration {
            transcription.duration = duration
        }
        try? modelContext.save()
    }
}

/// Step 2 of the pipeline: the deterministic cleanup every output mode, and re-transcription
/// from History, starts from. No user preferences and no LLM.
enum DictationTextProcessing {
    static func clean(
        _ transcript: String,
        formatsText: Bool,
        replaceWords: (String) -> String
    ) -> String {
        var text = TranscriptionOutputFilter.filter(transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if formatsText {
            text = WhisperTextFormatter.format(text)
        }
        text = replaceWords(text)
        // Offline dictation commands ("new line", "scratch that", spoken punctuation)
        // run as a deterministic post-processor so they work without the LLM prompt.
        return DictationCommandProcessor.process(text)
    }
}

// MARK: - Transcription timeout helper

private struct TranscriptionTimeoutError: LocalizedError {
    var errorDescription: String? { String(localized: "Transcription timed out after 120 seconds. The audio was kept — retry from History.") }
    var recoverySuggestion: String? { String(localized: "If this keeps happening, try reloading the model in Settings.") }
}

extension TranscriptionPipeline {
    /// Cocoa and Whisper cancel paths surface as "The operation could not be completed"
    /// with no mention of timeout or a missing file. That is what History row 14155 stored.
    static func describeTranscriptionFailure(_ error: Error) -> String {
        if error is CancellationError {
            return String(localized: "Transcription was cancelled. The audio was kept — retry from History.")
        }
        if error is TranscriptionTimeoutError {
            return error.localizedDescription
        }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == 260 {
            return String(localized: "The recording file could not be opened. If the audio is still in History, retry from there.")
        }
        let lower = nsError.localizedDescription.lowercased()
        if lower.contains("operation could not be completed")
            || lower.contains("operation couldn't be completed") {
            return String(localized: "Transcription was interrupted (the file was still being written, or the 120s limit cancelled Whisper). The audio should still be in Recordings — retry from History.")
        }
        return nsError.localizedDescription
    }
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
