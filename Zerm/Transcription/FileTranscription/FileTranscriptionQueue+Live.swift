import Foundation
import SwiftData

extension FileTranscriptionQueue {
    /// The app's queue: Zerm's transcription services, FluidAudio diarization and History.
    static func live(
        engine: ZermEngine,
        modelManager: TranscriptionModelManager,
        modelContext: ModelContext
    ) -> FileTranscriptionQueue {
        let registry = engine.serviceRegistry
        let history = FileTranscriptionHistory(modelContext: modelContext, store: .recordings)
        let steps = Steps(
            convert: { source, destination in
                try await AudioFileConverter.convert(source, to: destination)
            },
            transcribe: { audio, options, onProgress in
                let model = try await MainActor.run { try usableModel(named: options.modelName, in: modelManager) }
                let transcriber = WindowedFileTranscriber { window in
                    do {
                        let text = try await registry.transcribe(
                            audioURL: window,
                            model: model,
                            languageCode: options.languageCode
                        )
                        return TranscriptionOutputFilter.filter(text)
                    } catch CloudTranscriptionError.noTranscriptionReturned {
                        // Cloud providers answer a silent window with an empty body.
                        return ""
                    }
                }
                let transcript = try await transcriber.transcribeFile(audio, onProgress: onProgress)
                let segments = await MainActor.run {
                    transcript.segments.map { segment in
                        TranscriptSegment(
                            id: segment.id,
                            start: segment.start,
                            end: segment.end,
                            text: WordReplacementService.shared.applyReplacements(to: segment.text, using: engine.modelContext),
                            speakerIndex: segment.speakerIndex,
                            speakerConfidence: segment.speakerConfidence
                        )
                    }
                }
                return WindowedFileTranscriber.Transcript(segments: segments, gaps: transcript.gaps)
            },
            diarize: { audio, speakers, onProgress in
                try await FileDiarizer.diarize(audio, speakers: speakers, onProgress: onProgress)
            },
            save: { transcript, audio, duration in
                try history.save(transcript, audio: audio, transcriptionDuration: duration)
            },
            update: { transcript in
                history.update(transcript)
            }
        )

        return FileTranscriptionQueue(
            steps: steps,
            workDirectory: AppStoragePaths.root.appendingPathComponent("FileTranscription", isDirectory: true),
            defaultOptions: {
                let current = modelManager.currentTranscriptionModel
                return FileTranscriptionOptions(
                    modelName: current?.name ?? "",
                    modelDisplayName: current?.displayName ?? "",
                    languageCode: current?.isMultilingualModel == false ? "en" : LanguagePreference.selectedCode()
                )
            }
        )
    }

    /// The model a job was created with, if it can still run: downloaded, or with an API key.
    static func usableModel(named name: String, in modelManager: TranscriptionModelManager) throws -> any TranscriptionModel {
        if let model = modelManager.usableModels.first(where: { $0.name == name }) {
            return model
        }
        guard let model = modelManager.allAvailableModels.first(where: { $0.name == name }) else {
            throw FileTranscriptionError.noModelSelected
        }
        if isOnDevice(model.provider) {
            throw FileTranscriptionError.modelUnavailable(model.displayName)
        }
        throw FileTranscriptionError.cloudKeyMissing(model.displayName)
    }

    /// Whether a provider runs on this Mac rather than a cloud service.
    static func isOnDevice(_ provider: ModelProvider) -> Bool {
        switch provider {
        case .whisper, .fluidAudio, .nativeApple: true
        default: false
        }
    }
}
