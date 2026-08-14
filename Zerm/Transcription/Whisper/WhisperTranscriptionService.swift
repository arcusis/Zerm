import Foundation
import AVFoundation
import SwiftData
import os

class WhisperTranscriptionService: TranscriptionService {

    private var whisperContext: WhisperContext?
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

        // Read the provider's loaded-model state in ONE hop onto the main actor.
        //
        // This used to be four chained `await`s against @MainActor properties. Each one is a
        // separate suspension that has to be scheduled behind whatever else the main actor is
        // doing — and at this exact moment the main actor is busy publishing `.transcribing`
        // to the recorder views. Measured across eight dictations, those hops cost a median of
        // 402 ms (range 270–449 ms) between "Starting transcription" and this method's first
        // line of real work. Collapsing them also makes the read atomic: previously the model
        // could be unloaded between the `isModelLoaded` check and the `whisperContext` read.
        struct LoadedModelState {
            let context: WhisperContext?
            let name: String?
        }
        var loaded: LoadedModelState?
        if let provider = modelProvider {
            loaded = await MainActor.run {
                LoadedModelState(
                    context: provider.isModelLoaded ? provider.whisperContext : nil,
                    name: provider.loadedWhisperModel?.name
                )
            }
        }

        if let loadedContext = loaded?.context, loaded?.name == model.name {
            logger.notice("Using already loaded model: \(model.name, privacy: .public)")
            whisperContext = loadedContext
        } else {
            // Resolve the on-disk URL using the provider's availableModels (covers imports)
            let resolvedURL: URL? = await modelProvider?.availableModels.first(where: { $0.name == model.name })?.url
            guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
                throw ZermEngineError.modelLoadFailed
            }

            logger.notice("Loading model: \(model.name, privacy: .public)")
            do {
                whisperContext = try await WhisperContext.createContext(path: modelURL.path)
            } catch {
                logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error.localizedDescription, privacy: .public)")
                throw ZermEngineError.modelLoadFailed
            }
        }

        guard let whisperContext = whisperContext else {
            logger.error("❌ Cannot transcribe: Model could not be loaded")
            throw ZermEngineError.modelLoadFailed
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
        // When the active input source is Hebrew, compare one forced-Hebrew pass and keep it only
        // when the result is both Hebrew-script and comparably probable. Auto remains the primary
        // path, and long recordings never pay for a second inference.
        if WhisperLanguageCandidateSelector.shouldEvaluateFallback(
            selectedLanguage: selectedLanguage,
            shouldConsiderHebrew: shouldConsiderHebrew,
            detectedLanguage: candidate.languageCode,
            durationSeconds: durationSeconds
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

        // Only release resources if we created a new context (not using the shared one)
        if await modelProvider?.whisperContext !== whisperContext {
            await whisperContext.releaseResources()
            self.whisperContext = nil
        }

        return text
    }

}
