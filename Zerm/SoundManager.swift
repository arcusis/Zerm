import Foundation
import AppKit
import AVFoundation
import SwiftUI

private final class AudioPlayerCompletionDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinished: () -> Void
    init(_ onFinished: @escaping () -> Void) { self.onFinished = onFinished }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinished() }
    }
}

@MainActor
class SoundManager: ObservableObject {
    static let shared = SoundManager()

    private var startSound: AVAudioPlayer?
    private var stopSound: AVAudioPlayer?
    private var escSound: AVAudioPlayer?
    private var customStartSound: AVAudioPlayer?
    private var customStopSound: AVAudioPlayer?
    private var startSoundDelegate: AudioPlayerCompletionDelegate?
    private var clipboardPlayers: [String: AVAudioPlayer] = [:]
    private var clipboardSystemSounds: [String: NSSound] = [:]

    @AppStorage("isSoundFeedbackEnabled") private var isSoundFeedbackEnabled = true

    private init() {
        Task(priority: .background) {
            await setupSounds()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadCustomSounds),
            name: NSNotification.Name("CustomSoundsChanged"),
            object: nil
        )
    }

    func setupSounds() async {
        if let startSoundURL = Bundle.main.url(forResource: "recstart", withExtension: "mp3"),
           let stopSoundURL = Bundle.main.url(forResource: "recstop", withExtension: "mp3"),
           let escSoundURL = Bundle.main.url(forResource: "esc", withExtension: "wav") {
            try? await loadSounds(start: startSoundURL, stop: stopSoundURL, esc: escSoundURL)
        }

        await reloadCustomSoundsAsync()
    }

    @objc private func reloadCustomSounds() {
        Task {
            await reloadCustomSoundsAsync()
        }
    }

    private func loadAndPreparePlayer(from url: URL?) -> AVAudioPlayer? {
        guard let url = url else { return nil }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.4
        player?.prepareToPlay()
        return player
    }

    private func reloadCustomSoundsAsync() async {
        if customStartSound?.isPlaying == true {
            customStartSound?.stop()
        }
        if customStopSound?.isPlaying == true {
            customStopSound?.stop()
        }

        customStartSound = loadAndPreparePlayer(from: CustomSoundManager.shared.getCustomSoundURL(for: .start))
        customStopSound = loadAndPreparePlayer(from: CustomSoundManager.shared.getCustomSoundURL(for: .stop))
    }

    private func loadSounds(start startURL: URL, stop stopURL: URL, esc escURL: URL) async throws {
        do {
            startSound = try AVAudioPlayer(contentsOf: startURL)
            stopSound = try AVAudioPlayer(contentsOf: stopURL)
            escSound = try AVAudioPlayer(contentsOf: escURL)

            await MainActor.run {
                startSound?.prepareToPlay()
                stopSound?.prepareToPlay()
                escSound?.prepareToPlay()
            }

            startSound?.volume = 0.4
            stopSound?.volume = 0.4
            escSound?.volume = 0.3
        } catch {
            throw error
        }
    }

    func playStartSound(onFinished: (() -> Void)? = nil) {
        guard isSoundFeedbackEnabled else {
            onFinished?()
            return
        }
        guard let player = customStartSound ?? startSound else {
            onFinished?()
            return
        }
        player.volume = 0.4
        if let onFinished {
            let delegate = AudioPlayerCompletionDelegate(onFinished)
            startSoundDelegate = delegate
            player.delegate = delegate
        } else {
            startSoundDelegate = nil
            player.delegate = nil
        }
        player.play()
    }

    func playStopSound() {
        guard isSoundFeedbackEnabled else { return }

        if let custom = customStopSound {
            custom.play()
        } else {
            stopSound?.volume = 0.4
            stopSound?.play()
        }
    }
    
    func playEscSound() {
        guard isSoundFeedbackEnabled else { return }
        escSound?.volume = 0.3
        escSound?.play()
    }

    func playClipboardCopySound() { playClipboardSound(key: ClipboardHistorySettings.Keys.copySound, fallback: "Pop") }
    func playClipboardPasteSound() { playClipboardSound(key: ClipboardHistorySettings.Keys.pasteSound, fallback: "Purr") }
    func playClipboardDeleteSound() { playClipboardSound(key: ClipboardHistorySettings.Keys.deleteSound, fallback: "Basso") }
    func playClipboardSelectionSound() { playClipboardSound(key: ClipboardHistorySettings.Keys.selectionSound, fallback: "Tink") }

    func previewClipboardSound(key: String, fallback: String, volume: Double) {
        let choice = ClipboardHistorySettings.soundChoice(for: key, fallback: fallback)
        playClipboardSound(choice, id: key, volume: volume)
    }

    private func playClipboardSound(key: String, fallback: String) {
        let choice = ClipboardHistorySettings.soundChoice(for: key, fallback: fallback)
        guard choice != .none else { return }
        let volumeKey = key + "Volume"
        let volume = min(1, max(0, UserDefaults.standard.object(forKey: volumeKey) as? Double ?? 0.22))
        playClipboardSound(choice, id: key, volume: volume)
    }

    private func playClipboardSound(_ choice: ClipboardHistorySoundChoice, id: String, volume: Double) {
        switch choice {
        case .none:
            return
        case .system(let name):
            guard let sound = NSSound(named: NSSound.Name(name)) else { return }
            sound.volume = Float(volume)
            clipboardSystemSounds[id] = sound
            sound.play()
        case .custom(let bookmark):
            let choice = ClipboardHistorySoundChoice.custom(bookmark)
            guard let url = choice.customURL else { return }
            let hasScope = url.startAccessingSecurityScopedResource()
            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
            player.volume = Float(volume)
            player.prepareToPlay()
            clipboardPlayers[id] = player
            player.play()
        }
    }
    
    var isEnabled: Bool {
        get { isSoundFeedbackEnabled }
        set {
            objectWillChange.send()
            isSoundFeedbackEnabled = newValue
        }
    }
} 
