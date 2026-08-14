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
    /// Per-run token: cancel/new recording invalidates prior pipeline so late
    /// results cannot paste stale text or dismiss a newer session.
    private(set) var pipelineRunToken = UUID()
    private var pipelineTask: Task<Void, Never>?
    private var busyWatchdogTask: Task<Void, Never>?
    private var whisperIdleUnloadTask: Task<Void, Never>?
    private let whisperIdleUnloadSeconds: TimeInterval = 120
    private var memoryPressureSource: DispatchSourceMemoryPressure?

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
        startMemoryPressureMonitor()
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
            setState(.transcribing)
            recorder.stopRecording()

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
                    invalidatePipelineRun()
                    currentSession?.cancel()
                    currentSession = nil
                    try? FileManager.default.removeItem(at: recordedFile)
                    setState(.idle)
                    await cleanupResources()
                }
            } else {
                logger.error("❌ No recorded file found after stopping recording")
                DebugLogger.shared.log("ZermEngine", "no recorded file after stopping recording")
                invalidatePipelineRun()
                currentSession?.cancel()
                currentSession = nil
                setState(.idle)
                await cleanupResources()
            }
        } else if recordingState == .idle {
            logger.notice("toggleRecord: entering start-recording branch")
            guard let selectedModel = transcriptionModelManager.currentTranscriptionModel else {
                NotificationManager.shared.showNotification(
                    title: "No AI Model Selected",
                    type: .error,
                    duration: 5.0,
                    actionButton: (label: "Open Models", action: {
                        MenuBarManager.shared?.openMainWindowAndNavigate(to: "Dictation Models")
                    })
                )
                return
            }
            // Selection alone is not enough — model must be downloaded / API key present.
            let isUsable = transcriptionModelManager.usableModels.contains { $0.name == selectedModel.name }
            guard isUsable else {
                let message: String
                switch selectedModel.provider {
                case .whisper, .fluidAudio:
                    message = "Model not downloaded — download \(selectedModel.displayName) first"
                case .nativeApple:
                    message = "Apple Speech is not available on this system"
                default:
                    message = "Add an API key for \(selectedModel.displayName) in Settings"
                }
                NotificationManager.shared.showNotification(
                    title: message,
                    type: .error,
                    duration: 5.0,
                    actionButton: (label: "Open Models", action: {
                        MenuBarManager.shared?.openMainWindowAndNavigate(to: "Dictation Models")
                    })
                )
                return
            }
            shouldCancelRecording = false
            partialTranscript = ""
            invalidatePipelineRun()
            cancelWhisperIdleUnload()
            setState(.starting)

            requestRecordPermission { [self] granted in
                if granted {
                    let fileName = "\(UUID().uuidString).wav"
                    let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                    self.recordedFile = permanentURL

                    let pendingChunks = OSAllocatedUnfairLock(initialState: [Data]())
                    self.recorder.onAudioChunk = { data in
                        pendingChunks.withLock { $0.append(data) }
                    }

                    self.logger.notice("toggleRecord: starting audio hardware")

                    self.recorder.startRecording(toOutputFile: permanentURL) { result in
                        Task { @MainActor [self] in
                            do {
                                try result.get()
                                self.logger.notice("toggleRecord: audio hardware started successfully")

                                // Enter .recording only now that CoreAudio is delivering
                                // samples — same reasoning as the start sound below.  Setting
                                // it before hardware init mounted the AudioVisualizer against
                                // a zeroed meter, so it rendered flat bars indistinguishable
                                // from StaticVisualizer and then snapped to life ~280 ms later.
                                self.setState(.recording)
                                self.logger.notice("toggleRecord: state=recording")

                                // Play start sound NOW — CoreAudio is running, so this is
                                // the true "go" cue for the user.  Previously the sound
                                // played ~1 s before hardware init, losing the first words
                                // spoken on the cue. (VoiceInk #572)
                                // Mute only after the cue finishes, and only if still
                                // recording — prevents cancel-during-sound from leaving
                                // output stuck muted (generation + state guard).
                                SoundManager.shared.playStartSound {
                                    Task { @MainActor [weak self] in
                                        guard let self else { return }
                                        guard self.recordingState == .recording,
                                              !self.shouldCancelRecording else {
                                            return
                                        }
                                        _ = await MediaController.shared.muteSystemAudio()
                                    }
                                }

                                guard self.recorderUIManager?.isMiniRecorderVisible ?? false, !self.shouldCancelRecording else {
                                    self.cancelAutoStopMonitor()
                                    MediaController.shared.cancelPendingMute()
                                    await MediaController.shared.unmuteSystemAudio()
                                    self.recorder.stopRecording()
                                    self.recordedFile = nil
                                    self.setState(.idle)
                                    return
                                }

                                await ActiveWindowService.shared.applyConfiguration(
                                    powerModeId: powerModeId,
                                    shouldApplyURLMatch: { [weak self] in
                                        self?.recordingState == .recording
                                    }
                                )
                                self.startAutoStopMonitor()

                                if self.recordingState == .recording,
                                   let model = self.transcriptionModelManager.currentTranscriptionModel {
                                    let session = self.serviceRegistry.createSession(
                                        for: model,
                                        onPartialTranscript: { [weak self] partial in
                                            Task { @MainActor in
                                                // A provider can deliver a partial after the
                                                // recording it belongs to has stopped. Without
                                                // this guard that late text lands in the UI of
                                                // whatever session is live now.
                                                guard let self,
                                                      self.recordingState == .recording,
                                                      !self.shouldCancelRecording else {
                                                    return
                                                }
                                                self.partialTranscript = partial
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
                                                self.logger.error("❌ Model loading failed: \(error.localizedDescription, privacy: .public)")
                                            }
                                        }
                                    } else if let fluidAudioModel = await self.transcriptionModelManager.currentTranscriptionModel as? FluidAudioModel {
                                        try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(for: fluidAudioModel)
                                    }

                                    if let enhancementService = self.enhancementService {
                                        let captureSettings = await MainActor.run {
                                            (
                                                mode: DictationOutputMode.current,
                                                enabled: enhancementService.isEnhancementEnabled,
                                                clipboard: enhancementService.useClipboardContext,
                                                screen: enhancementService.useScreenCaptureContext
                                            )
                                        }

                                        // Refine has a few seconds in total, so the on-device model must
                                        // already be resident by the time transcription finishes — a cold
                                        // Gemma load alone would exhaust the whole budget.
                                        if captureSettings.mode == .instantRefine, captureSettings.enabled {
                                            await LocalLLMModelManager.shared.prewarm()
                                        }

                                        if captureSettings.mode.usesEnhancement && captureSettings.enabled {
                                            if captureSettings.clipboard {
                                                await MainActor.run {
                                                    enhancementService.captureClipboardContext()
                                                }
                                            }
                                            // Screen capture is only affordable when the paste waits for
                                            // the result anyway.
                                            if captureSettings.screen, captureSettings.mode == .enhanced {
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
                                self.setState(.idle)
                                self.recordedFile = nil
                                NotificationManager.shared.showNotification(title: "Recording failed to start", type: .error)
                                self.logger.notice("toggleRecord: calling dismissMiniRecorder from error handler")
                                await self.recorderUIManager?.dismissMiniRecorder()
                            }
                        }
                    }
                } else {
                    logger.error("❌ Recording permission denied.")
                    DebugLogger.shared.log("ZermEngine", "recording blocked: microphone permission denied")
                    NotificationManager.shared.showNotification(
                        title: "Microphone access denied — enable Zerm in System Settings → Privacy & Security → Microphone",
                        type: .error,
                        duration: 6.0,
                        actionButton: (label: "Open Settings", action: {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        })
                    )
                    setState(.idle)
                    Task { await self.recorderUIManager?.dismissMiniRecorder() }
                }
            }
        } else {
            logger.notice("toggleRecord ignored while lifecycle is busy (state=\(String(describing: self.recordingState), privacy: .public))")
        }
    }

    // MARK: - State transitions

    /// Single chokepoint for lifecycle transitions (logged + watchdog for stuck states).
    func setState(_ newState: RecordingState) {
        let old = recordingState
        guard old != newState else { return }
        logger.notice("state \(String(describing: old), privacy: .public) → \(String(describing: newState), privacy: .public)")
        recordingState = newState
        restartBusyWatchdogIfNeeded()
    }

    private func invalidatePipelineRun() {
        pipelineRunToken = UUID()
        pipelineTask?.cancel()
        pipelineTask = nil
        busyWatchdogTask?.cancel()
        busyWatchdogTask = nil
    }

    private func restartBusyWatchdogIfNeeded() {
        busyWatchdogTask?.cancel()
        busyWatchdogTask = nil
        let stuckStates: Set<RecordingState> = [.transcribing, .enhancing, .busy, .starting]
        guard stuckStates.contains(recordingState) else { return }
        let tokenAtStart = pipelineRunToken
        let stateAtStart = recordingState
        busyWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000) // 3 minutes
            guard let self, !Task.isCancelled else { return }
            guard self.pipelineRunToken == tokenAtStart, self.recordingState == stateAtStart else { return }
            self.logger.error("Watchdog: stuck in \(String(describing: stateAtStart), privacy: .public) — recovering to idle")
            DebugLogger.shared.log("ZermEngine", "watchdog: stuck in \(stateAtStart) — force idle")
            self.shouldCancelRecording = true
            self.invalidatePipelineRun()
            self.setState(.idle)
            NotificationManager.shared.showNotification(
                title: "Zerm recovered from a stuck state — try again",
                type: .warning,
                duration: 4.0
            )
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
                    DebugLogger.shared.log("ZermEngine", "watchdog: no audio input for \(String(format: "%.1f", sinceInput))s — recording dropped")
                    NotificationManager.shared.showNotification(
                        title: "Recording stopped — microphone dropped",
                        type: .warning,
                        duration: 3.0
                    )
                    // Stop and transcribe whatever was captured before the drop,
                    // then return cleanly to idle so the next press starts fresh.
                    self.stopFromMonitor()
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
                    DebugLogger.shared.log("ZermEngine", "auto-stop: silence threshold reached after \(String(format: "%.1f", elapsed))s")
                    self.stopFromMonitor()
                    return
                }

                if !heardSpeech, elapsed >= initialSilenceSeconds {
                    self.logger.notice("Auto-stop: initial silence timeout reached")
                    DebugLogger.shared.log("ZermEngine", "auto-stop: initial silence timeout, no speech detected in \(String(format: "%.1f", elapsed))s")
                    self.stopFromMonitor()
                    return
                }
            }
        }
    }

    /// Stops the recording on behalf of the auto-stop monitor.
    ///
    /// Must run as a NEW unstructured task, never `await self.toggleRecord()`
    /// from inside `autoStopTask`: toggleRecord's first step cancels that very
    /// task, so the whole stop → transcribe → paste pipeline would then run in
    /// an already-cancelled task. `Task.sleep` inside the transcription timeout
    /// throws CancellationError immediately, and the pipeline discards the
    /// capture as if the user had cancelled — the recording is silently lost.
    private func stopFromMonitor() {
        Task { @MainActor in
            await self.toggleRecord()
        }
    }

    private func cancelAutoStopMonitor() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    private func requestRecordPermission(response: @escaping @MainActor (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        DebugLogger.shared.log("ZermEngine", "microphone permission status=\(Self.describe(status))")
        switch status {
        case .authorized:
            // Already on the main actor, and this is a plain enum read — answer inline.
            // Wrapping it in a Task queued the callback behind the recorder panel's
            // first render pass, costing ~310 ms of dead UI on every trigger.
            response(true)
        case .notDetermined:
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                DebugLogger.shared.log("ZermEngine", "microphone permission requested, granted=\(granted)")
                response(granted)
            }
        default:
            response(false)
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(on transcription: Transcription, audioURL: URL) async {
        guard let model = transcriptionModelManager.currentTranscriptionModel else {
            transcription.text = "Transcription Failed: No model selected"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            setState(.idle)
            NotificationManager.shared.showNotification(
                title: "Transcription failed: No model selected",
                type: .error,
                duration: 5.0,
                actionButton: (label: "Open Models", action: {
                    MenuBarManager.shared?.openMainWindowAndNavigate(to: "Dictation Models")
                })
            )
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
        let runToken = pipelineRunToken

        // Refine and Read Aloud queue on the same on-device model actor. Read Aloud is
        // something the user just asked for; a refine is speculative, so it gives way.
        RefineInPlaceCoordinator.shared.shouldYield = { [weak self] in
            self?.recorderUIManager?.isReadAloudActive ?? false
        }

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            model: model,
            session: session,
            onStateChange: { [weak self] state in
                guard let self, self.pipelineRunToken == runToken else { return }
                self.setState(state)
            },
            shouldCancel: { [weak self] in
                guard let self else { return true }
                return self.shouldCancelRecording || self.pipelineRunToken != runToken
            },
            isRunStillValid: { [weak self] in
                guard let self else { return false }
                return self.pipelineRunToken == runToken && !self.shouldCancelRecording
            },
            onCleanup: { [weak self] in await self?.cleanupResources() },
            onDismiss: { [weak self] in
                guard let self, self.pipelineRunToken == runToken else { return }
                await self.recorderUIManager?.dismissMiniRecorder()
            }
        )

        shouldCancelRecording = false
        if pipelineRunToken == runToken, recordingState != .idle {
            setState(.idle)
        }
        scheduleWhisperIdleUnload()
    }

    // MARK: - Resource Cleanup

    func cleanupResources() async {
        cancelAutoStopMonitor()
        // Keep Whisper warm across rapid dictations; unload on idle timer instead.
        // FluidAudio sessions and streaming state still need release.
        logger.notice("cleanupResources: releasing non-Whisper resources")
        await serviceRegistry.cleanup()
        scheduleWhisperIdleUnload()
        logger.notice("cleanupResources: completed")
    }

    private func cancelWhisperIdleUnload() {
        whisperIdleUnloadTask?.cancel()
        whisperIdleUnloadTask = nil
    }

    private func scheduleWhisperIdleUnload() {
        cancelWhisperIdleUnload()
        whisperIdleUnloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.whisperIdleUnloadSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.recordingState == .idle else { return }
            // A refine runs after the recorder has gone back to idle, so the state check
            // above does not cover it.
            guard !RefineInPlaceCoordinator.shared.isRefining else { return }
            // Keep Whisper warm for low-latency dictation. The much larger local LLM manages its
            // own short burst window and unloads independently so it does not reserve unified
            // memory between enhancement or Read Aloud jobs.
            self.logger.notice("Idle after \(self.whisperIdleUnloadSeconds, privacy: .public)s — keeping Whisper warm")
        }
    }

    /// Releases the Whisper context only when the system is actually short of memory.
    ///
    /// Previously the context was unloaded on a flat 120 s idle timer, which meant any
    /// dictation started more than two minutes after the last one paid a full model reload
    /// (~800 ms for large-v3-turbo-q5_0, measured via ModelPrewarmService) before a single
    /// sample was transcribed. That is the difference between "instant" and "sometimes it
    /// hangs". Keeping the model resident and yielding it on memory pressure gives the fast
    /// path all the time while still being a good citizen when the machine is squeezed.
    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.recordingState == .idle else { return }
                self.logger.notice("Memory pressure — releasing Whisper context")
                await self.whisperModelManager.cleanupResources()
                LocalLLMModelManager.shared.unloadIfIdle()
            }
        }
        source.resume()
        memoryPressureSource = source
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
