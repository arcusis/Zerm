import AVFoundation
import Combine
import Foundation
import OSLog

/// Plays back a recorded meeting and reports where it has got to, so the transcript can follow
/// along and a line can be clicked to jump to the moment it was said.
///
/// Both source tracks are replayed against the persisted meeting clock. Each remains independently
/// mutable/soloable, and discontinuities are rendered as silence rather than compressing time.
@MainActor
final class MeetingPlayer: NSObject, ObservableObject {

    enum Track: String, CaseIterable, Identifiable, Hashable {
        case mix
        case microphone
        case systemAudio

        var id: String { rawValue }
        var title: String {
            switch self {
            case .mix: return String(localized: "Room + Call")
            case .microphone: return String(localized: "Room")
            case .systemAudio: return String(localized: "Call")
            }
        }
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var track: Track = .mix
    @Published private(set) var roomMuted = false
    @Published private(set) var callMuted = false
    @Published private(set) var errorMessage: String?

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "MeetingPlayer")
    private var players: [Track: AVAudioPlayer] = [:]
    private var ticker: Timer?
    private var item: MeetingRecordingStore.Item?
    private var clockAnchors: [Track: [MeetingClockAnchor]] = [:]
    private var playbackOriginUptime: TimeInterval?

    // MARK: - Loading

    func load(_ item: MeetingRecordingStore.Item, track: Track? = nil) {
        stop()
        self.item = item
        // Fall back to whichever track exists rather than failing: a system-audio-only recording
        // is perfectly valid.
        let wanted = track ?? .mix
        self.track = wanted
        openTracks()
        applyMixSelection()
    }

    func select(track: Track) {
        guard track != self.track else { return }
        self.track = track
        applyMixSelection()
    }

    func setMuted(_ muted: Bool, for track: Track) {
        switch track {
        case .mix:
            roomMuted = muted
            callMuted = muted
        case .microphone: roomMuted = muted
        case .systemAudio: callMuted = muted
        }
        applyMixSelection()
    }

    func toggleSolo(_ track: Track) {
        self.track = self.track == track ? .mix : track
        applyMixSelection()
    }

    private func openTracks() {
        guard let item else { return }
        players = [:]
        clockAnchors = [:]
        let manifest = MeetingRecordingStore.readManifest(in: item.folder)
        for (source, url) in [(Track.microphone, item.microphoneTrack), (.systemAudio, item.systemAudioTrack)] {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[source] = player
                let anchors = manifest?.tracks.first {
                    $0.fileName == url.lastPathComponent
                }?.clockAnchors ?? []
                clockAnchors[source] = anchors
                duration = max(duration, MeetingTrackClock.meetingTime(
                    forFileTime: player.duration,
                    anchors: anchors
                ))
            } catch {
                logger.error("Could not open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        duration = max(duration, item.duration)
        currentTime = 0
        errorMessage = players.isEmpty
            ? String(localized: "This recording has no playable audio tracks.") : nil
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !players.isEmpty else { return }
        playbackOriginUptime = ProcessInfo.processInfo.systemUptime + 0.05 - currentTime
        isPlaying = true
        synchronizePlayers(force: true)
        startTicking()
    }

    func pause() {
        players.values.forEach { $0.pause() }
        playbackOriginUptime = nil
        isPlaying = false
        stopTicking()
    }

    func stop() {
        players.values.forEach { $0.stop() }
        players = [:]
        clockAnchors = [:]
        playbackOriginUptime = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTicking()
    }

    /// Jumping to a transcript line lands slightly before it, so the first word is not clipped.
    func seek(to time: TimeInterval, lead: TimeInterval = 0.35) {
        let meetingTarget = max(0, time - lead)
        currentTime = meetingTarget
        if isPlaying { playbackOriginUptime = ProcessInfo.processInfo.systemUptime - meetingTarget }
        synchronizePlayers(force: true)
    }

    // MARK: - Clock

    private func startTicking() {
        stopTicking()
        let ticker = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let origin = self.playbackOriginUptime else { return }
                self.currentTime = min(self.duration, ProcessInfo.processInfo.systemUptime - origin)
                if self.currentTime >= self.duration {
                    self.pause()
                    return
                }
                self.synchronizePlayers(force: false)
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func applyMixSelection() {
        players[.microphone]?.volume = roomMuted || track == .systemAudio ? 0 : 1
        players[.systemAudio]?.volume = callMuted || track == .microphone ? 0 : 1
    }

    private func synchronizePlayers(force: Bool) {
        let synchronizedDeviceStart: TimeInterval?
        if force, isPlaying, let reference = players.values.first {
            synchronizedDeviceStart = reference.deviceCurrentTime + 0.05
        } else {
            synchronizedDeviceStart = nil
        }
        for source in [Track.microphone, .systemAudio] {
            guard let player = players[source] else { continue }
            let anchors = clockAnchors[source] ?? []
            let shouldSound = MeetingTrackClock.containsAudio(
                atMeetingTime: currentTime,
                fileDuration: player.duration,
                anchors: anchors
            )
            let target = MeetingTrackClock.fileTime(
                forMeetingTime: currentTime,
                anchors: anchors
            )
            if force || abs(player.currentTime - target) > 0.08 {
                player.currentTime = max(0, min(player.duration, target))
            }
            if isPlaying, shouldSound {
                if let synchronizedDeviceStart {
                    player.play(atTime: synchronizedDeviceStart)
                } else if !player.isPlaying {
                    // A track waking after a persisted timeline gap must rejoin at the exact
                    // meeting-clock position. The ordinary drift tolerance is useful while two
                    // tracks are already running, but applying it here would make a small resume
                    // offset permanent and produce room/call echo.
                    player.currentTime = max(0, min(player.duration, target))
                    player.play()
                }
            } else if player.isPlaying {
                player.pause()
            }
        }
        applyMixSelection()
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
