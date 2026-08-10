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

    private let player = TTSPlayer()
    private let naturalizer = TTSNaturalizer()
    private var task: Task<Void, Never>?
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
        guard startSession() else { return }
        task = Task { await self.fetchAndSpeak() }
    }

    func stop() {
        task?.cancel()
        task = nil
        player.stop()
        isSpeaking = false
        recorderUIManager?.endSpeaking()
        AudioOutputRouteMonitor.shared.clearAmbiguousAnalogHeadphoneConfirmation()
    }

    /// Synthesizes and plays arbitrary text (e.g. the settings Preview button).
    func speak(_ text: String) async {
        guard startSession() else { return }
        await synthesizeAndPlay(text)
    }

    /// Reserves the recorder widget and shows the "Preparing…" state immediately.
    private func startSession() -> Bool {
        let routeMonitor = AudioOutputRouteMonitor.shared
        if MeetingActivityMonitor.shared.isActive,
           routeMonitor.route != .headphones {
            let message = routeMonitor.isAmbiguousAnalogOutput
                ? String(localized: "Confirm wired headphones in Read Aloud settings before speaking during this meeting")
                : String(localized: "Connect headphones to use Read Aloud during a meeting")
            notify(message)
            SoundManager.shared.playEscSound()
            return false
        }
        if let rm = recorderUIManager, !rm.canStartSpeaking {
            notify(String(localized: "Finish or cancel dictation before using Read Aloud"))
            SoundManager.shared.playEscSound()
            return false
        }
        isSpeaking = true
        recorderUIManager?.beginSpeaking()
        return true
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
        if let message { notify(message) }
        if beep { SoundManager.shared.playEscSound() }
        isSpeaking = false
        recorderUIManager?.endSpeaking()
        AudioOutputRouteMonitor.shared.clearAmbiguousAnalogHeadphoneConfirmation()
    }

    /// Reads whatever text is currently selected system-wide.
    private func fetchAndSpeak() async {
        guard let raw = await SelectedTextService.fetchSelectedText(),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            endSession(String(localized: "No text selected"), beep: true)
            return
        }
        await synthesizeAndPlay(raw)
    }

    /// Chunked, streaming synthesis + playback. Assumes a session is already started.
    private func synthesizeAndPlay(_ text: String) async {
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

        let speed = TTSSettings.speed
        // Instant cleanup first so first audio can start without waiting on the full
        // on-device naturalize. Remaining chunks may be refined per-sentence.
        let cleaned = prepareInstantText(from: text)
        guard !Task.isCancelled else { return }
        let chunks = Self.splitIntoChunks(cleaned)
        let useAI = TTSSettings.naturalReadingAI && naturalizer.isModelInstalled

        player.startStreaming { [weak self] in
            self?.isSpeaking = false
            self?.recorderUIManager?.endSpeaking()
            AudioOutputRouteMonitor.shared.clearAmbiguousAnalogHeadphoneConfirmation()
        }

        var startedPlaying = false
        do {
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                // The first chunk is the audio the user is waiting on, so it is never sent
                // through the on-device LLM — that rewrite costs ~2 s and, when the model
                // declines to rewrite, the result is discarded anyway. Later chunks are
                // rewritten while the earlier ones are already playing, so their cost is free.
                let spokenChunk: String
                // Chunks 0 AND 1 skip the LLM. Chunk 0 is what the user is waiting for; chunk 1
                // has to be ready before chunk 0 finishes playing, and a first sentence is often
                // under a second of audio while a rewrite takes 3–5 s — which produced an audible
                // stall right after the opening sentence. From chunk 2 on, ~220 chars is ~15 s of
                // buffered audio, comfortably more than a rewrite costs.
                if useAI, index > 1 {
                    spokenChunk = await naturalizer.naturalize(chunk, isCancelled: { Task.isCancelled }) ?? chunk
                } else {
                    spokenChunk = chunk
                }
                try Task.checkCancellation()
                let audio = try await provider.synthesize(text: spokenChunk, voice: voice, speed: speed, apiKey: apiKey)
                try Task.checkCancellation()
                try player.enqueue(audio)
                if !startedPlaying {
                    startedPlaying = true
                    recorderUIManager?.markSpeechPlaying()   // first chunk → live audio bars
                }
            }
            player.finishEnqueueing()
            TTSSettings.recordReadAloud(of: text)
        } catch is CancellationError {
            // stop() already cleaned up the widget + player.
        } catch {
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

    /// Makes the selection sound human before synthesis. The instant offline normalizer ALWAYS
    /// runs first (so emoji/symbols/markup are stripped no matter what); the on-device LLM then
    /// refines that clean text into natural prose. If the model misbehaves (e.g. answers instead
    /// of rewriting) the naturalizer returns nil and we speak the cleaned text — never junk.
    private func prepareSpokenText(from raw: String) async -> String {
        let cleaned = prepareInstantText(from: raw)

        if TTSSettings.naturalReadingAI, naturalizer.isModelInstalled {
            recorderUIManager?.beginGenerating()          // widget shows "Thinking…"
            let rewritten = await naturalizer.naturalize(cleaned, isCancelled: { Task.isCancelled })
            recorderUIManager?.endGenerating()            // back to "Preparing…" for synthesis
            if let rewritten { return rewritten }
        }
        return cleaned
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

    private func notify(_ message: String) {
        statusMessage = message
        logger.notice("\(message, privacy: .public)")
        NotificationManager.shared.showNotification(title: message, type: .info, duration: 3.0)
    }
}
