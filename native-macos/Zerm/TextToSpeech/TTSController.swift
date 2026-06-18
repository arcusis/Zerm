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

    init() {}

    /// Registers the global Read Aloud shortcut. Call exactly once, from app startup.
    func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .readSelectedTextAloud) { [weak self] in
            self?.toggle()
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

        isSpeaking = true
        do {
            let audio = try await provider.synthesize(text: text, voice: voice, speed: TTSSettings.speed, apiKey: apiKey)
            if Task.isCancelled { isSpeaking = false; return }
            try player.play(audio) { [weak self] in
                self?.isSpeaking = false
            }
            TTSSettings.recordReadAloud(of: text)
        } catch is CancellationError {
            isSpeaking = false
        } catch {
            isSpeaking = false
            logger.error("Read Aloud failed: \(error.localizedDescription, privacy: .public)")
            notify("Read Aloud failed: \(error.localizedDescription)")
        }
    }

    private func notify(_ message: String) {
        statusMessage = message
        logger.notice("\(message, privacy: .public)")
    }
}
