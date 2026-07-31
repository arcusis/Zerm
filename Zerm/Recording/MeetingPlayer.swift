import AVFoundation
import Combine
import Foundation
import OSLog

/// Plays back a recorded meeting and reports where it has got to, so the transcript can follow
/// along and a line can be clicked to jump to the moment it was said.
///
/// Plays the microphone track by default and can switch to the system track: the two are kept
/// separate on disk, so "hear my side" and "hear theirs" are just a choice of file rather than
/// anything that has to be unmixed.
@MainActor
final class MeetingPlayer: NSObject, ObservableObject {

    enum Track: String, CaseIterable, Identifiable {
        case microphone
        case systemAudio

        var id: String { rawValue }
        var title: String { self == .microphone ? "Room" : "Call" }
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var track: Track = .microphone
    @Published private(set) var errorMessage: String?

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingPlayer")
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var item: MeetingRecordingStore.Item?

    // MARK: - Loading

    func load(_ item: MeetingRecordingStore.Item, track: Track? = nil) {
        stop()
        self.item = item
        // Fall back to whichever track exists rather than failing: a system-audio-only recording
        // is perfectly valid.
        let wanted = track ?? (item.microphoneTrack != nil ? .microphone : .systemAudio)
        self.track = wanted
        openCurrentTrack()
    }

    func select(track: Track) {
        guard track != self.track else { return }
        let resumeAt = currentTime
        let wasPlaying = isPlaying
        self.track = track
        openCurrentTrack()
        seek(to: resumeAt)
        if wasPlaying { play() }
    }

    private func openCurrentTrack() {
        guard let item else { return }
        let url = track == .microphone ? item.microphoneTrack : item.systemAudioTrack
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            player = nil
            duration = 0
            errorMessage = "That track is not part of this recording."
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            errorMessage = nil
        } catch {
            player = nil
            duration = 0
            errorMessage = error.localizedDescription
            logger.error("Could not open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTicking()
    }

    /// Jumping to a transcript line lands slightly before it, so the first word is not clipped.
    func seek(to time: TimeInterval, lead: TimeInterval = 0.35) {
        guard let player else { return }
        let target = max(0, min(player.duration, time - lead))
        player.currentTime = target
        currentTime = target
    }

    // MARK: - Clock

    private func startTicking() {
        stopTicking()
        let ticker = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension MeetingPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTicking()
            self.currentTime = self.duration
        }
    }
}

extension MeetingRecordingStore.Sidecar {
    /// The line being spoken at `time`, for highlighting the transcript during playback.
    func line(at time: TimeInterval) -> Int? {
        segments.firstIndex { time >= $0.start && time < $0.end }
            // Past the last line — keep the final one highlighted rather than losing the cursor.
            ?? (segments.last.map { time >= $0.end } == true ? segments.count - 1 : nil)
    }
}
