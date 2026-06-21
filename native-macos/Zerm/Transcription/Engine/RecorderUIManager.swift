import Foundation
import SwiftUI
import os

@MainActor
class RecorderUIManager: ObservableObject {
    @Published var miniRecorderError: String?

    @Published var recorderType: String = UserDefaults.standard.string(forKey: "RecorderType") ?? "mini" {
        didSet {
            if isMiniRecorderVisible {
                if oldValue == "notch" {
                    notchWindowManager?.destroyWindow()
                    notchWindowManager = nil
                } else {
                    miniWindowManager?.destroyWindow()
                    miniWindowManager = nil
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    showRecorderPanel()
                }
            }
            UserDefaults.standard.set(recorderType, forKey: "RecorderType")
        }
    }

    @Published var isMiniRecorderVisible = false {
        didSet {
            if isMiniRecorderVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }

    var notchWindowManager: NotchWindowManager?
    var miniWindowManager: MiniWindowManager?

    private weak var engine: ZermEngine?
    private var recorder: Recorder?

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "RecorderUIManager")

    init() {}

    /// Call after ZermEngine is created to break the circular init dependency.
    func configure(engine: ZermEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        setupNotifications()
    }

    // MARK: - Read Aloud (TTS) widget

    /// Stops Read Aloud playback. Set by the app to TTSController.stop().
    var onCancelSpeaking: (() -> Void)?

    /// True while Read Aloud owns the widget (thinking, synthesizing, or playing).
    var isReadAloudActive: Bool {
        let s = engine?.recordingState
        return s == .speaking || s == .preparingSpeech || s == .generatingSpeech
    }

    /// Whether Read Aloud may start — only when nothing else is using the recorder.
    var canStartSpeaking: Bool {
        guard let engine = engine else { return true }
        return engine.recordingState == .idle && !isMiniRecorderVisible
    }

    /// Shows the recorder widget in the "Preparing…" loading state (no microphone/recording).
    func beginSpeaking() {
        guard let engine = engine else { return }
        engine.recordingState = .preparingSpeech
        isMiniRecorderVisible = true
    }

    /// Shows the "Thinking…" state while the on-device AI rewrites the text.
    func beginGenerating() {
        guard let engine = engine else { return }
        if engine.recordingState == .preparingSpeech {
            engine.recordingState = .generatingSpeech
        }
    }

    /// Returns to "Preparing…" once the AI rewrite finishes and synthesis begins.
    func endGenerating() {
        guard let engine = engine else { return }
        if engine.recordingState == .generatingSpeech {
            engine.recordingState = .preparingSpeech
        }
    }

    /// Switches the widget from the loading states to the live audio bars once playback starts.
    func markSpeechPlaying() {
        guard let engine = engine else { return }
        if engine.recordingState == .preparingSpeech || engine.recordingState == .generatingSpeech {
            engine.recordingState = .speaking
        }
    }

    /// Hides the widget after Read Aloud finishes or is cancelled.
    func endSpeaking() {
        guard let engine = engine else { return }
        if isReadAloudActive {
            engine.recordingState = .idle
        }
        isMiniRecorderVisible = false
    }

    /// Cancels whatever the recorder is currently doing — Read Aloud or a recording.
    func cancelActiveOperation() async {
        if isReadAloudActive {
            onCancelSpeaking?()
        } else {
            await cancelRecording()
        }
    }

    // MARK: - Recorder Panel Management

    func showRecorderPanel() {
        guard let engine = engine, let recorder = recorder else { return }
        logger.notice("Showing \(self.recorderType, privacy: .public) recorder")

        if recorderType == "notch" {
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(engine: engine, recorder: recorder)
            }
            notchWindowManager?.show()
        } else {
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(engine: engine, recorder: recorder)
            }
            miniWindowManager?.show()
        }
    }

    func hideRecorderPanel() {
        if recorderType == "notch" {
            notchWindowManager?.hide()
        } else {
            miniWindowManager?.hide()
        }
    }

    // MARK: - Mini Recorder Management

    func toggleMiniRecorder(powerModeId: UUID? = nil) async {
        guard let engine = engine else { return }
        logger.notice("toggleMiniRecorder called – visible=\(self.isMiniRecorderVisible, privacy: .public), state=\(String(describing: engine.recordingState), privacy: .public)")

        // If Read Aloud is using the widget, this gesture stops it (don't start a recording).
        if isReadAloudActive {
            onCancelSpeaking?()
            return
        }

        if isMiniRecorderVisible {
            if engine.recordingState == .recording {
                logger.notice("toggleMiniRecorder: stopping recording (was recording)")
                await engine.toggleRecord(powerModeId: powerModeId)
            } else {
                logger.notice("toggleMiniRecorder: cancelling (was not recording)")
                await cancelRecording()
            }
        } else {
            // Show the recorder panel immediately (visual feedback) but delay the
            // start sound until CoreAudio confirms it is running — see ZermEngine.toggleRecord.
            // Playing the sound before CoreAudio is ready caused a ~1 s gap where speech
            // was lost because users started speaking on the sound cue. (VoiceInk #572)
            await MainActor.run { isMiniRecorderVisible = true }
            await engine.toggleRecord(powerModeId: powerModeId)
        }
    }

    func dismissMiniRecorder() async {
        guard let engine = engine, let recorder = recorder else { return }
        logger.notice("dismissMiniRecorder called – state=\(String(describing: engine.recordingState), privacy: .public)")

        if isReadAloudActive {
            onCancelSpeaking?()
            return
        }

        if engine.recordingState == .busy {
            logger.notice("dismissMiniRecorder: early return, state is busy")
            return
        }

        let wasRecording = engine.recordingState == .recording

        await MainActor.run {
            engine.recordingState = .busy
        }

        // Cancel and release any active streaming session to prevent resource leaks.
        engine.currentSession?.cancel()
        engine.currentSession = nil

        if wasRecording {
            await recorder.stopRecording()
        }

        hideRecorderPanel()

        // Clear captured context when the recorder is dismissed
        if let enhancementService = engine.enhancementService {
            await MainActor.run {
                enhancementService.clearCapturedContexts()
            }
        }

        await MainActor.run {
            isMiniRecorderVisible = false
        }

        await engine.cleanupResources()

        if !UserDefaults.standard.bool(forKey: "powerModePersistConfig") {
            await PowerModeSessionManager.shared.endSession()
            await MainActor.run {
                PowerModeManager.shared.setActiveConfiguration(nil)
            }
        }

        await MainActor.run {
            engine.recordingState = .idle
        }
        logger.notice("dismissMiniRecorder completed")
    }

    func resetOnLaunch() async {
        guard let engine = engine, let recorder = recorder else { return }
        logger.notice("Resetting recording state on launch")
        await recorder.stopRecording()
        hideRecorderPanel()
        await MainActor.run {
            isMiniRecorderVisible = false
            engine.shouldCancelRecording = false
            miniRecorderError = nil
            engine.recordingState = .idle
        }
        await engine.cleanupResources()
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        logger.notice("cancelRecording called")
        SoundManager.shared.playEscSound()
        engine.shouldCancelRecording = true
        await dismissMiniRecorder()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleMiniRecorder),
            name: .toggleMiniRecorder,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissMiniRecorder),
            name: .dismissMiniRecorder,
            object: nil
        )
    }

    @objc public func handleToggleMiniRecorder() {
        logger.notice("handleToggleMiniRecorder: .toggleMiniRecorder notification received")
        Task {
            await toggleMiniRecorder()
        }
    }

    @objc public func handleDismissMiniRecorder() {
        logger.notice("handleDismissMiniRecorder: .dismissMiniRecorder notification received")
        Task {
            await dismissMiniRecorder()
        }
    }
}
