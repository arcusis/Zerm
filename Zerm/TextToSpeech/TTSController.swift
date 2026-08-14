import Combine
import Foundation
import KeyboardShortcuts
import os

extension KeyboardShortcuts.Name {
    // Ships with a sensible default (⌃⌥R) so Read Aloud works out of the box; the user can rebind it.
    static let readSelectedTextAloud = Self("readSelectedTextAloud", default: .init(.r, modifiers: [.control, .option]))
}

/// Orchestrates the Read Aloud feature: hotkey → fetch selected text → synthesize → play.
/// The synthesis mirror of `ZermEngine`'s record→transcribe→paste flow.
@MainActor
final class TTSController: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published var statusMessage: String?
    @Published private(set) var lastPreparedText: String?

    private let player = TTSPlayer()
    private let naturalizer = TTSNaturalizer()
    private var task: Task<Void, Never>?
    private var sessionGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TTSController")

    weak var engine: ZermEngine?
    weak var recorderUIManager: RecorderUIManager?

    init(engine: ZermEngine? = nil, recorderUIManager: RecorderUIManager? = nil) {
        self.engine = engine
        self.recorderUIManager = recorderUIManager
        _ = MeetingActivityMonitor.shared

        // Feed the TTS output level into the recorder's meter so the widget shows live
        // audio bars while speaking — the same visualizer dictation uses. Capture the
        // recorder directly (a plain class) to avoid main-actor isolation in the tap.
        let recorderRef = engine?.recorder
        player.onLevel = { level in
            recorderRef?.audioMeter = AudioMeter(averagePower: level, peakPower: level)
        }

        AudioOutputRouteMonitor.shared.$route
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] route in
                Task { @MainActor [weak self] in self?.outputRouteChanged(to: route) }
            }
            .store(in: &cancellables)
    }

    /// Hotkey action: start reading the selection, or stop if already speaking.
    func toggle() {
        guard TTSSettings.isEnabled else { return }
        if isSpeaking {
            stop()
            return
        }
        // Show the widget INSTANTLY (before fetching text / synthesizing) so Read Aloud feels
        // as immediate as dictation; the fetch + synthesis happen asynchronously after.
        guard let generation = startSession() else { return }
        task = Task { await self.fetchAndSpeak(generation: generation) }
    }

    func stop() {
        sessionGeneration += 1
        task?.cancel()
        task = nil
        player.stop()
        isSpeaking = false
        recorderUIManager?.endSpeaking()
        AudioOutputRouteMonitor.shared.clearAmbiguousAnalogHeadphoneConfirmation()
    }

    /// Synthesizes and plays arbitrary text (e.g. the settings Preview button).
    func speak(_ text: String) async {
        guard let generation = startSession() else { return }
        await synthesizeAndPlay(text, mode: .exact, generation: generation)
    }

    /// Reserves the recorder widget and shows the "Preparing…" state immediately.
    private func startSession() -> Int? {
        let routeMonitor = AudioOutputRouteMonitor.shared
        if MeetingActivityMonitor.shared.isActive,
           routeMonitor.route != .headphones {
            let message = routeMonitor.isAmbiguousAnalogOutput
                ? String(localized: "Confirm wired headphones in Read Aloud settings before speaking during this meeting")
                : String(localized: "Connect headphones to use Read Aloud during a meeting")
            notify(message)
            SoundManager.shared.playEscSound()
            return nil
        }
        if let rm = recorderUIManager, !rm.canStartSpeaking {
            notify(String(localized: "Finish or cancel dictation before using Read Aloud"))
            SoundManager.shared.playEscSound()
            return nil
        }
        sessionGeneration += 1
        let generation = sessionGeneration
        isSpeaking = true
        recorderUIManager?.beginSpeaking()
        return generation
    }

    /// Called synchronously by the application-scoped meeting coordinator before it starts
    /// either capture source. A notification/task hop is too late: speaker audio could already
    /// have reached the first microphone buffers by the time the MainActor handled it.
    func prepareForMeetingCapture() {
        // A new meeting is a new acoustic-safety boundary. The analog jack cannot distinguish
        // headphones from powered speakers, so any prior confirmation must be made again.
        AudioOutputRouteMonitor.shared.clearAmbiguousAnalogHeadphoneConfirmation()
        guard isSpeaking, AudioOutputRouteMonitor.shared.route != .headphones else { return }
        stop()
        notify(String(localized: "Read Aloud stopped because the meeting is using speakers"))
    }

    private func outputRouteChanged(to route: AudioOutputRoute) {
        guard MeetingActivityMonitor.shared.isActive, isSpeaking, route != .headphones else { return }
        stop()
        notify(String(localized: "Read Aloud stopped because headphones disconnected during the meeting"))
    }

    private func endSession(_ message: String? = nil, beep: Bool = false) {
        sessionGeneration += 1
        if let message { notify(message) }
        if beep { SoundManager.shared.playEscSound() }
        isSpeaking = false
        recorderUIManager?.endSpeaking()
        AudioOutputRouteMonitor.shared.clearAmbiguousAnalogHeadphoneConfirmation()
    }

    /// Reads whatever text is currently selected system-wide.
    private func fetchAndSpeak(generation: Int) async {
        guard let raw = await SelectedTextService.fetchSelectedText(),
              generation == sessionGeneration,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if generation == sessionGeneration {
                endSession(String(localized: "No text selected"), beep: true)
            }
            return
        }
        await synthesizeAndPlay(raw, mode: TTSSettings.readingMode, generation: generation)
    }

    /// Chunked, streaming synthesis + playback. Assumes a session is already started.
    private func synthesizeAndPlay(_ text: String, mode: ReadAloudMode, generation: Int) async {
        guard generation == sessionGeneration else { return }
        guard let provider = TTSProviderRegistry.provider(for: TTSSettings.providerKind) else {
            endSession(String(localized: "No speech provider selected"), beep: true); return
        }

        var apiKey = ""
        if let providerID = provider.apiKeyProviderID {
            apiKey = APIKeyManager.shared.getAPIKey(forProvider: providerID) ?? ""
            if provider.requiresAPIKey && apiKey.isEmpty {
                let format = String(localized: "Add an API key for %@ in Read Aloud settings")
                endSession(String.localizedStringWithFormat(format, provider.displayName), beep: true)
                return
            }
        }

        guard let voice = TTSSettings.resolvedVoice(for: provider) else {
            let format = String(localized: "No voice available for %@")
            endSession(String.localizedStringWithFormat(format, provider.displayName), beep: true); return
        }

        if provider.kind == .kokoro, Self.containsHebrew(text) {
            endSession(
                String(localized: "Kokoro currently supports English only. Choose an installed Hebrew Apple System Voice in Models & Voices."),
                beep: true
            )
            MenuBarManager.shared?.openMainWindowAndNavigate(to: "Read Aloud Models")
            return
        }

        let speed = TTSSettings.speed
        let spokenText: String
        do {
            if mode.usesLocalAI {
                guard naturalizer.isModelInstalled else {
                    endSession(String(localized: "Download an on-device language model before using AI Read Aloud modes."), beep: true)
                    MenuBarManager.shared?.openMainWindowAndNavigate(to: "Read Aloud Models")
                    return
                }
                recorderUIManager?.beginGenerating()
                spokenText = try await naturalizer.transform(
                    // Let the model analyze the original complete selection. Pre-normalizing here
                    // destroys structure (lists, URLs, code and tables) that Retell/Explain need
                    // in order to understand the content before producing spoken prose.
                    text.trimmingCharacters(in: .whitespacesAndNewlines),
                    mode: mode,
                    isCancelled: { Task.isCancelled }
                )
                guard generation == sessionGeneration else { return }
                recorderUIManager?.endGenerating()
            } else {
                // Exact mode skips semantic rewriting but retains the user's deterministic
                // Smart Cleanup preference for pronounceable URLs, code and symbols.
                spokenText = prepareInstantText(from: text)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == sessionGeneration else { return }
            let format = String(localized: "Read Aloud failed: %@")
            endSession(String.localizedStringWithFormat(format, error.localizedDescription), beep: true)
            return
        }
        guard !Task.isCancelled, generation == sessionGeneration, !spokenText.isEmpty else { return }
        lastPreparedText = spokenText
        let chunks = Self.splitIntoChunks(spokenText)

        player.startStreaming { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                TTSSettings.recordReadAloud(of: spokenText)
                ReadAloudHistoryStore.shared.record(
                    sourceText: text,
                    spokenText: spokenText,
                    mode: mode,
                    providerName: provider.displayName,
                    voiceName: voice.displayName,
                    localModelName: mode.usesLocalAI ? LocalLLMModelManager.current.displayName : nil
                )
                self.isSpeaking = false
                self.recorderUIManager?.endSpeaking()
                AudioOutputRouteMonitor.shared.clearAmbiguousAnalogHeadphoneConfirmation()
            }
        }

        var startedPlaying = false
        do {
            for chunk in chunks {
                try Task.checkCancellation()
                let audio = try await provider.synthesize(text: chunk, voice: voice, speed: speed, apiKey: apiKey)
                try Task.checkCancellation()
                guard generation == sessionGeneration else { return }
                try await player.enqueue(audio)
                if !startedPlaying {
                    startedPlaying = true
                    recorderUIManager?.markSpeechPlaying()   // first chunk → live audio bars
                }
            }
            player.finishEnqueueing()
        } catch is CancellationError {
            // stop() already cleaned up the widget + player.
        } catch {
            guard generation == sessionGeneration else { return }
            player.stop()
            logger.error("Read Aloud failed: \(error.localizedDescription, privacy: .public)")
            let format = String(localized: "Read Aloud failed: %@")
            endSession(String.localizedStringWithFormat(format, error.localizedDescription))
        }
    }

    /// Instant offline cleanup only (no LLM) so first audio can start immediately.
    private func prepareInstantText(from raw: String) -> String {
        let base = TTSSettings.smartCleanup ? TTSTextNormalizer.normalize(raw) : raw
        return base.isEmpty ? raw : base
    }

    /// Splits text into sentence-based chunks. The first chunk is a single sentence (so audio
    /// starts fast); later chunks accumulate to ~220 chars to limit per-chunk overhead.
    private static func splitIntoChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            guard let sub, !sub.isEmpty else { return }
            current += sub
            let threshold = chunks.isEmpty ? 1 : 220
            if current.count >= threshold {
                chunks.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [text] : chunks
    }

    private static func containsHebrew(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }
    }

    private func notify(_ message: String) {
        statusMessage = message
        logger.notice("\(message, privacy: .public)")
        NotificationManager.shared.showNotification(title: message, type: .info, duration: 3.0)
    }
}
