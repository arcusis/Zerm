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
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "TTSController")

    weak var engine: ZermEngine?
    weak var recorderUIManager: RecorderUIManager?

    init(engine: ZermEngine? = nil, recorderUIManager: RecorderUIManager? = nil) {
        self.engine = engine
        self.recorderUIManager = recorderUIManager

        // Feed the TTS output level into the recorder's meter so the widget shows live
        // audio bars while speaking — the same visualizer dictation uses. Capture the
        // recorder directly (a plain class) to avoid main-actor isolation in the tap.
        let recorderRef = engine?.recorder
        player.onLevel = { level in
            recorderRef?.audioMeter = AudioMeter(averagePower: level, peakPower: level)
        }
    }

    /// Hotkey action: start reading the selection, or stop if already speaking.
    func toggle() {
        guard TTSSettings.isEnabled else { return }
        if isSpeaking {
            stop()
            return
        }
        task = Task { await self.speakSelection() }
    }

    func stop() {
        task?.cancel()
        task = nil
        player.stop()
        isSpeaking = false
        recorderUIManager?.endSpeaking()
    }

    /// Reads whatever text is currently selected system-wide.
    func speakSelection() async {
        guard let raw = await SelectedTextService.fetchSelectedText(),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notify("No text selected")
            SoundManager.shared.playEscSound()
            return
        }
        await speak(raw)
    }

    /// Synthesizes and plays arbitrary text using the configured provider/voice.
    func speak(_ text: String) async {
        // Mutual exclusion: never run Read Aloud while dictation owns the recorder widget.
        if let rm = recorderUIManager, !rm.canStartSpeaking {
            notify("Finish or cancel dictation before using Read Aloud")
            SoundManager.shared.playEscSound()
            return
        }

        guard let provider = TTSProviderRegistry.provider(for: TTSSettings.providerKind) else {
            notify("No speech provider selected")
            return
        }

        var apiKey = ""
        if let providerID = provider.apiKeyProviderID {
            apiKey = APIKeyManager.shared.getAPIKey(forProvider: providerID) ?? ""
            if provider.requiresAPIKey && apiKey.isEmpty {
                notify("Add an API key for \(provider.displayName) in Read Aloud settings")
                return
            }
        }

        guard let voice = TTSSettings.resolvedVoice(for: provider) else {
            notify("No voice available for \(provider.displayName)")
            return
        }

        let speed = TTSSettings.speed
        let chunks = Self.splitIntoChunks(text)

        isSpeaking = true
        recorderUIManager?.beginSpeaking()
        player.startStreaming { [weak self] in
            self?.isSpeaking = false
            self?.recorderUIManager?.endSpeaking()
        }

        var startedPlaying = false
        do {
            for chunk in chunks {
                try Task.checkCancellation()
                let audio = try await provider.synthesize(text: chunk, voice: voice, speed: speed, apiKey: apiKey)
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
            isSpeaking = false
            recorderUIManager?.endSpeaking()
            logger.error("Read Aloud failed: \(error.localizedDescription, privacy: .public)")
            notify("Read Aloud failed: \(error.localizedDescription)")
        }
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
