import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentError: TranscriptionError?

    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "AudioTranscriptionService")
    private let serviceRegistry: TranscriptionServiceRegistry

    enum TranscriptionError: Error {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
    }

    init(modelContext: ModelContext, engine: ZermEngine) {
        self.modelContext = modelContext
        self.enhancementService = engine.enhancementService
        self.serviceRegistry = engine.serviceRegistry
    }

    init(modelContext: ModelContext, serviceRegistry: TranscriptionServiceRegistry, enhancementService: AIEnhancementService?) {
        self.modelContext = modelContext
        self.enhancementService = enhancementService
        self.serviceRegistry = serviceRegistry
    }

    /// Transcribes a saved recording again with the same text pipeline as dictation: deterministic
    /// cleanup, the user's preferences, then enhancement of the cleaned text under the global
    /// output mode. No Power Mode applies — the recording is not tied to a frontmost app anymore.
    func retranscribeAudio(from url: URL, using model: any TranscriptionModel) async throws -> Transcription {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let transcriptionStart = Date()
            let transcript = try await serviceRegistry.transcribe(audioURL: url, model: model)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            let textCleanup = TextCleanupPreferences.global()
            let cleanedText = DictationTextProcessing.clean(transcript, formatsText: textCleanup.formatsText) { [modelContext] text in
                WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            }
            let text = textCleanup.applyPreferences(to: cleanedText)

            let audioAsset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            let recordingsDirectory = AppStoragePaths.root
                .appendingPathComponent("Recordings")

            let fileName = "retranscribed_\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)

            do {
                try FileManager.default.copyItem(at: url, to: permanentURL)
            } catch {
                logger.error("❌ Failed to create permanent copy of audio: \(error.localizedDescription, privacy: .public)")
                throw error
            }

            // The transcription itself succeeded; an enhancement that does not is recorded on the
            // same completed row, which belongs in the metrics either way.
            let newTranscription = Transcription(
                text: text,
                duration: duration,
                audioFileURL: permanentURL.absoluteString,
                transcriptionModelName: model.displayName,
                transcriptionDuration: transcriptionDuration,
                transcriptionStatus: .completed
            )

            if let enhancementService, !text.isEmpty {
                let plan = enhancementService.plan(
                    for: cleanedText,
                    configuredMode: enhancementService.outputMode,
                    autoSendEnabled: false,
                    overrides: EnhancementOverrides()
                )
                if plan.outputMode.usesEnhancement, !plan.input.isEmpty {
                    if plan.skipsAsShort {
                        newTranscription.record(.skipped(.shortTranscription), of: nil)
                    } else {
                        switch enhancementService.makeRequest(input: plan.input, purpose: .enhanced, overrides: plan.overrides) {
                        case .failure(let reason):
                            let outcome = EnhancementOutcome.skipped(.notConfigured(reason))
                            newTranscription.record(outcome, of: nil)
                            EnhancementNotifier.shared.report(outcome, purpose: .manual)
                        case .success(let request):
                            let outcome = await enhancementService.perform(request)
                            newTranscription.record(outcome, of: request, finalize: textCleanup.applyPreferences(to:))
                            EnhancementNotifier.shared.report(outcome, purpose: .manual)
                        }
                    }
                }
            }

            modelContext.insert(newTranscription)
            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .transcriptionCreated, object: newTranscription)
                NotificationCenter.default.post(name: .transcriptionCompleted, object: newTranscription)
            } catch {
                logger.error("❌ Failed to save transcription: \(error.localizedDescription, privacy: .public)")
            }
            UsageStatsService.shared.record(newTranscription)

            return newTranscription
        } catch {
            logger.error("❌ Transcription failed: \(error.localizedDescription, privacy: .public)")
            currentError = .transcriptionFailed
            throw error
        }
    }
}
