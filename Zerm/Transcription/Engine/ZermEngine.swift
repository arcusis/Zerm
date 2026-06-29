import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import os

@MainActor
class ZermEngine: NSObject, ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    var partialTranscript: String = ""
    var currentSession: TranscriptionSession?

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderUIManager?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.arcusis.zerm", category: "ZermEngine")
    private var autoStopTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.arcusis.zerm")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        if let enhancementService {
            PowerModeSessionManager.shared.configure(engine: self, enhancementService: enhancementService)
        }

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    // MARK: - Toggle Record

    func toggleRecord(powerModeId: UUID? = nil) async {
        logger.notice("toggleRecord called – state=\(String(describing: self.recordingState), privacy: .public)")

        if recordingState == .recording {
            cancelAutoStopMonitor()
            partialTranscript = ""
            recordingState = .transcribing
            await recorder.stopRecording()

            if let recordedFile {
                if !shouldCancelRecording {
                    let transcription = Transcription(
                        text: "",
                        duration: 0,
                        audioFileURL: recordedFile.absoluteString,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    await runPipeline(on: transcription, audioURL: recordedFile)
                } else {
                    currentSession?.cancel()
                    currentSession = nil
                    try? FileManager.default.removeItem(at: recordedFile)
                    recordingState = .idle
                    await cleanupResources()
                }
            } else {
                logger.error("❌ No recorded file found after stopping recording")
                currentSession?.cancel()
                currentSession = nil
                recordingState = .idle
                await cleanupResources()
            }
        } else if recordingState == .idle {
            logger.notice("toggleRecord: entering start-recording branch")
            guard transcriptionModelManager.currentTranscriptionModel != nil else {
                NotificationManager.shared.showNotification(title: "No AI Model Selected", type: .error)
                return
            }
            shouldCancelRecording = false
            partialTranscript = ""
            recordingState = .starting

            requestRecordPermission { [self] granted in
                if granted {
                    let fileName = "\(UUID().uuidString).wav"
                    let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                    self.recordedFile = permanentURL

                    let pendingChunks = OSAllocatedUnfairLock(initialState: [Data]())
                    self.recorder.onAudioChunk = { data in
                        pendingChunks.withLock { $0.append(data) }
                    }

                    self.recordingState = .recording
                    self.logger.notice("toggleRecord: state=recording, starting audio hardware")

                    self.recorder.startRecording(toOutputFile: permanentURL) { result in
                        Task { @MainActor [self] in
                            do {
                                try result.get()
                                self.logger.notice("toggleRecord: audio hardware started successfully")

                                // Play start sound NOW — CoreAudio is running, so this is
                                // the true "go" cue for the user.  Previously the sound
                                // played ~1 s before hardware init, losing the first words
                                // spoken on the cue. (VoiceInk #572)
                                SoundManager.shared.playStartSound {
                                    Task { await MediaController.shared.muteSystemAudio() }
                                }

                                guard self.recorderUIManager?.isMiniRecorderVisible ?? false, !self.shouldCancelRecording else {
                                    self.cancelAutoStopMonitor()
                                    self.recorder.stopRecording()
                                    self.recordedFile = nil
                                    self.recordingState = .idle
                                    return
                                }

                                await ActiveWindowService.shared.applyConfiguration(powerModeId: powerModeId)
                                self.startAutoStopMonitor()

                                if self.recordingState == .recording,
                                   let model = self.transcriptionModelManager.currentTranscriptionModel {
                                    let session = self.serviceRegistry.createSession(
                                        for: model,
                                        onPartialTranscript: { [weak self] partial in
                                            Task { @MainActor in
                                                self?.partialTranscript = partial
                                            }
                                        }
                                    )
                                    self.currentSession = session
                                    let realCallback = try await session.prepare(model: model)

                                    if let realCallback {
                                        self.recorder.onAudioChunk = realCallback
                                        let buffered = pendingChunks.withLock { chunks -> [Data] in
                                            let result = chunks
                                            chunks.removeAll()
                                            return result
                                        }
                                        for chunk in buffered { realCallback(chunk) }
                                    } else {
                                        self.recorder.onAudioChunk = nil
                                        pendingChunks.withLock { $0.removeAll() }
                                    }
                                }

                                Task.detached { [weak self] in
                                    guard let self else { return }

                                    if let model = await self.transcriptionModelManager.currentTranscriptionModel,
                                       model.provider == .whisper {
                                        if let localWhisperModel = await self.whisperModelManager.availableModels.first(where: { $0.name == model.name }),
                                           await self.whisperModelManager.whisperContext == nil {
                                            do {
                                                try await self.whisperModelManager.loadModel(localWhisperModel)
                                            } catch {
                                                await self.logger.error("❌ Model loading failed: \(error.localizedDescription, privacy: .public)")
                                            }
                                        }
                                    } else if let fluidAudioModel = await self.transcriptionModelManager.currentTranscriptionModel as? FluidAudioModel {
                                        try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(for: fluidAudioModel)
                                    }

                                    if let enhancementService = await self.enhancementService {
                                        let captureSettings = await MainActor.run {
                                            (
                                                instant: UserDefaults.standard.bool(forKey: "InstantTranscriptionMode"),
                                                enabled: enhancementService.isEnhancementEnabled,
                                                clipboard: enhancementService.useClipboardContext,
                                                screen: enhancementService.useScreenCaptureContext
                                            )
                                        }

                                        if !captureSettings.instant && captureSettings.enabled {
                                            if captureSettings.clipboard {
                                                await MainActor.run {
                                                    enhancementService.captureClipboardContext()
                                                }
                                            }
                                            if captureSettings.screen {
                                                await enhancementService.captureScreenContext()
                                            }
                                        } else {
                                            await MainActor.run {
                                                enhancementService.clearCapturedContexts()
                                            }
                                        }
                                    }
                                }

                            } catch {
                                self.cancelAutoStopMonitor()
                                self.logger.error("❌ Failed to start recording: \(error.localizedDescription, privacy: .public)")
                                self.recordingState = .idle
                                self.recordedFile = nil
                                await NotificationManager.shared.showNotification(title: "Recording failed to start", type: .error)
                                self.logger.notice("toggleRecord: calling dismissMiniRecorder from error handler")
                                await self.recorderUIManager?.dismissMiniRecorder()
                            }
                        }
                    }
                } else {
                    logger.error("❌ Recording permission denied.")
                    recordingState = .idle
                }
            }
        } else {
            logger.notice("toggleRecord ignored while lifecycle is busy")
        }
    }

    private func startAutoStopMonitor() {
        cancelAutoStopMonitor()

        let defaults = UserDefaults.standard
        // The silence auto-stop is opt-out, but the loop always runs so the
        // dropped-capture watchdog below works regardless of that setting.
        let autoStopEnabled = defaults.bool(forKey: "AutoStopAfterSilence")
        let silenceSeconds = max(defaults.double(forKey: "AutoStopSilenceSeconds"), 0.6)
        let minimumRecordingSeconds = max(defaults.double(forKey: "AutoStopMinimumRecordingSeconds"), 0.3)
        let initialSilenceSeconds = max(defaults.double(forKey: "AutoStopInitialSilenceSeconds"), 2.0)
        let levelThreshold = max(defaults.double(forKey: "AutoStopLevelThreshold"), 0.02)
        // If the audio unit dies mid-recording (device unplugged, render error)
        // the input callback stops firing while the engine still believes it is
        // recording — the capture is silently lost and the UI gets stuck. If no
        // audio has arrived for this long after the unit was delivering, treat the
        // recording as dropped and recover.
        let captureStallSeconds = 3.0
        let startedAt = Date()

        autoStopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var heardSpeech = false
            var lastSpeechAt = startedAt

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                guard self.recordingState == .recording else { return }

                let now = Date()
                let elapsed = now.timeIntervalSince(startedAt)

                // Dropped-capture watchdog. `secondsSinceLastAudioInput` is non-nil
                // only once the callback has fired at least once, so this never
                // false-fires during the brief hardware start-up window.
                if let sinceInput = self.recorder.secondsSinceLastAudioInput,
                   sinceInput >= captureStallSeconds {
                    self.logger.error("Recording dropped: no audio input for \(sinceInput, privacy: .public)s — recovering")
                    await NotificationManager.shared.showNotification(
                        title: "Recording stopped — microphone dropped",
                        type: .warning,
                        duration: 3.0
                    )
                    // Stop and transcribe whatever was captured before the drop,
                    // then return cleanly to idle so the next press starts fresh.
                    await self.toggleRecord()
                    return
                }

                let level = max(self.recorder.audioMeter.averagePower, self.recorder.audioMeter.peakPower * 0.65)

                if level >= levelThreshold {
                    heardSpeech = true
                    lastSpeechAt = now
                    continue
                }

                guard autoStopEnabled else { continue }

                if heardSpeech,
                   elapsed >= minimumRecordingSeconds,
                   now.timeIntervalSince(lastSpeechAt) >= silenceSeconds {
                    self.logger.notice("Auto-stop: silence threshold reached")
                    await self.toggleRecord()
                    return
                }

                if !heardSpeech, elapsed >= initialSilenceSeconds {
                    self.logger.notice("Auto-stop: initial silence timeout reached")
                    await self.toggleRecord()
                    return
                }
            }
        }
    }

    private func cancelAutoStopMonitor() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(on transcription: Transcription, audioURL: URL) async {
        guard let model = transcriptionModelManager.currentTranscriptionModel else {
            transcription.text = "Transcription Failed: No model selected"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            recordingState = .idle
            return
        }

        // The model reload (started in toggleRecord's Task.detached) runs concurrently
        // with recording.  If the recording was short the load may still be in progress
        // when we reach this point.  Wait for it before running the pipeline so that
        // the first transcription after idle doesn't fail with a nil context.
        // (VoiceInk #614 / Zerm #15)
        if whisperModelManager.isModelLoading {
            logger.notice("runPipeline: model is loading, waiting…")
            var waited = 0
            while whisperModelManager.isModelLoading && waited < 60 {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
                waited += 1
            }
            if whisperModelManager.isModelLoading {
                logger.error("runPipeline: timed out waiting for model to load")
            }
        }

        let session = currentSession
        currentSession = nil

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            model: model,
            session: session,
            onStateChange: { [weak self] state in self?.recordingState = state },
            shouldCancel: { [weak self] in self?.shouldCancelRecording ?? false },
            onCleanup: { [weak self] in await self?.cleanupResources() },
            onDismiss: { [weak self] in await self?.recorderUIManager?.dismissMiniRecorder() }
        )

        shouldCancelRecording = false
        if recordingState != .idle {
            recordingState = .idle
        }
    }

    // MARK: - Resource Cleanup

    func cleanupResources() async {
        cancelAutoStopMonitor()
        logger.notice("cleanupResources: releasing model resources")
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLicenseStatusChanged),
            name: .licenseStatusChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handleLicenseStatusChanged() {
        pipeline.licenseViewModel = LicenseViewModel()
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}
