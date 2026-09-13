import Foundation
import AVFoundation
import SwiftData
import os

class WhisperTranscriptionService: TranscriptionService {

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?
    private let modelContext: ModelContext?

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil, modelContext: ModelContext? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
        self.modelContext = modelContext
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        guard model.provider == .whisper else {
            throw ZermEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        // With a model provider the context is the provider's resident one, loaded once and kept
        // warm; its fast path is a single main-actor hop. Without one (warmup of a freshly
        // downloaded model) a temporary context is loaded and released after this dictation.
        let whisperContext: WhisperContext
        let ownsContext: Bool
        if let modelProvider {
            whisperContext = try await modelProvider.loadModel(named: model.name)
            ownsContext = false
        } else {
            let modelURL = modelsDirectory.appendingPathComponent("\(model.name).bin")
            guard FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
                throw ZermEngineError.modelLoadFailed
            }
            logger.notice("Loading temporary model: \(model.name, privacy: .public)")
            do {
                whisperContext = try await WhisperContext.createContext(path: modelURL.path)
            } catch {
                logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                throw ZermEngineError.modelLoadFailed
            }
            ownsContext = true
        }

        // Read audio data — use AVAudioFile-based resampler so variable-length WAV
        // headers (non-standard RIFF chunks, LIST/INFO blocks, etc.) are handled
        // correctly rather than always skipping 44 bytes (VoiceInk #393).
        let data = try await AudioProcessor().processAudioToSamples(audioURL)
        let durationSeconds = Double(data.count) / 16_000.0
        let peak = data.map { abs($0) }.max() ?? 0
        let selectedLanguage = LanguagePreference.selectedCode()
        let shouldConsiderHebrew = selectedLanguage == LanguagePreference.autoCode
            ? await MainActor.run { LanguagePreference.prefersHebrewForAutomaticDetection() }
            : false
        DebugLogger.shared.log(
            "Whisper",
            "samples=\(data.count) dur=\(String(format: "%.2f", durationSeconds))s peak=\(String(format: "%.3f", peak)) model=\(model.name)"
        )

        guard !data.isEmpty else {
            logger.error("❌ No audio samples extracted from recording")
            DebugLogger.shared.log("Whisper", "empty sample buffer from audio file")
            throw ZermEngineError.transcriptionFailed
        }

        // Merge style prompt with custom dictionary so Whisper biases toward user terms.
        let basePrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
        let dictionarySuffix: String
        if let modelContext {
            dictionarySuffix = VocabularyTerms.whisperPromptSuffix(from: modelContext)
        } else {
            dictionarySuffix = ""
        }
        let currentPrompt = basePrompt + dictionarySuffix
        await whisperContext.setPrompt(currentPrompt)

        // Transcribe (with VAD if enabled)
        var success = await whisperContext.fullTranscribe(
            samples: data,
            languageCode: selectedLanguage
        )
        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw ZermEngineError.whisperCoreFailed
        }

        var candidate = await whisperContext.transcriptionCandidate()
        var text = candidate.text

        // VAD often drops short dictations that still have measurable energy — retry once
        // without VAD when the first pass is empty but the file is long enough to matter.
        let vadOn = UserDefaults.standard.bool(forKey: "IsVADEnabled")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           vadOn,
           durationSeconds >= 0.6,
           peak > 0.01 {
            logger.notice("Empty result with VAD — retrying without VAD (dur=\(durationSeconds, privacy: .public)s peak=\(peak, privacy: .public))")
            DebugLogger.shared.log("Whisper", "empty with VAD — retry without VAD")
            success = await whisperContext.fullTranscribe(
                samples: data,
                forceDisableVAD: true,
                languageCode: selectedLanguage
            )
            if success {
                candidate = await whisperContext.transcriptionCandidate()
                text = candidate.text
            }
        }

        // Short Hebrew phrases are Whisper's most common auto-detection failure in this app:
        // an English keyboard-independent auto pass can return confident-looking Latin text.
        // When the active keyboard is Hebrew, compare one forced-Hebrew pass and keep it only
        // when the result is Hebrew-script and actually competitive. Auto remains the primary
        // path. Preferred languages, pinned non-Hebrew modes, and long recordings never pay
        // for a second inference.
        if WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: selectedLanguage,
            shouldConsiderHebrew: shouldConsiderHebrew,
            detectedLanguage: candidate.languageCode,
            durationSeconds: durationSeconds,
            primaryText: candidate.text,
            primaryProbability: candidate.averageTokenProbability
        ) {
            let hebrewSucceeded = await whisperContext.fullTranscribe(
                samples: data,
                forceDisableVAD: true,
                languageCode: "he"
            )
            if hebrewSucceeded {
                let hebrewCandidate = await whisperContext.transcriptionCandidate()
                let chosen = WhisperLanguageCandidateSelector.choose(primary: candidate, hebrew: hebrewCandidate)
                if chosen == hebrewCandidate {
                    logger.notice("Auto language recovery selected Hebrew for a short dictation")
                }
                candidate = chosen
                text = chosen.text
            }
        }

        logger.notice("Whisper transcription completed: \(text.count, privacy: .public) characters")
        DebugLogger.shared.log("Whisper", "result chars=\(text.count) empty=\(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")

        if ownsContext {
            await whisperContext.releaseResources()
        }

        return text
    }

}
