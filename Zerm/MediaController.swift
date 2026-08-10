import Foundation
import CoreAudio
import os

final class MediaController: ObservableObject, @unchecked Sendable {

    static let shared = MediaController()

    /// Mute bookkeeping, guarded as one unit.
    ///
    /// `generation` is what makes a late mute safe to ignore: every start/stop bumps
    /// it, so a mute scheduled behind the start sound can tell whether the recording
    /// it belonged to is still the current one before touching system volume.
    private struct MuteState {
        var didMuteAudio = false
        var wasAudioMutedBeforeRecording = false
        var unmuteTask: Task<Void, Never>?
        var muteTask: Task<Void, Never>?
        var generation = 0

        /// Invalidates in-flight work and returns the new generation.
        mutating func nextGeneration() -> Int {
            generation += 1
            return generation
        }
    }

    // OSAllocatedUnfairLock rather than NSLock: every caller here is async, and
    // NSLock's lock()/unlock() are unavailable from async contexts (a hard error
    // under the Swift 6 language mode) because nothing stops a suspension point
    // from landing between them.
    private let state = OSAllocatedUnfairLock(initialState: MuteState())

    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet { UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled") }
    }

    @Published var audioResumptionDelay: Double = UserDefaults.standard.double(forKey: "audioResumptionDelay") {
        didSet { UserDefaults.standard.set(audioResumptionDelay, forKey: "audioResumptionDelay") }
    }

    @Published var skipMuteWithHeadphones: Bool = UserDefaults.standard.bool(forKey: "SkipMuteWithHeadphones") {
        didSet { UserDefaults.standard.set(skipMuteWithHeadphones, forKey: "SkipMuteWithHeadphones") }
    }

    private var meetingStartObserver: NSObjectProtocol?

    private init() {
        _ = MeetingActivityMonitor.shared
        meetingStartObserver = NotificationCenter.default.addObserver(
            forName: .meetingRecordingDidStart,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // A call must never remain muted because Dictation was already active when meeting
            // capture began. Dictation continues; only Zerm-owned muting is released.
            self?.restoreOutputForMeeting()
        }
    }

    /// Cancels any deferred mute so a quick cancel cannot leave the system muted
    /// after a late start-sound completion. Call from stop/cancel paths.
    func cancelPendingMute() {
        state.withLock { state in
            state.muteTask?.cancel()
            state.muteTask = nil
            _ = state.nextGeneration()
        }
    }

    /// Mutes system audio immediately (decoupled from start-sound playback).
    func muteSystemAudio() async -> Bool {
        guard isSystemMuteEnabled else { return false }
        guard !MeetingActivityMonitor.shared.isActive else {
            restoreOutputForMeeting()
            return false
        }

        let myGeneration = state.withLock { state -> Int in
            state.unmuteTask?.cancel()
            state.unmuteTask = nil
            state.muteTask?.cancel()
            state.muteTask = nil
            return state.nextGeneration()
        }

        return await performMute(generation: myGeneration)
    }

    /// Schedules mute after `delay` seconds, cancellable via `cancelPendingMute` / `unmuteSystemAudio`.
    func scheduleMuteSystemAudio(after delay: TimeInterval = 0) {
        guard isSystemMuteEnabled else { return }
        guard !MeetingActivityMonitor.shared.isActive else {
            restoreOutputForMeeting()
            return
        }

        let myGeneration = state.withLock { state -> Int in
            state.unmuteTask?.cancel()
            state.unmuteTask = nil
            state.muteTask?.cancel()
            return state.nextGeneration()
        }

        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            _ = await self.performMute(generation: myGeneration)
        }
        state.withLock { $0.muteTask = task }
    }

    private func performMute(generation: Int) async -> Bool {
        guard state.withLock({ $0.generation == generation }) else { return false }
        guard !MeetingActivityMonitor.shared.isActive else {
            restoreOutputForMeeting()
            return false
        }

        // Headphones cannot bleed back into the microphone, so there is nothing to
        // protect the transcript from. Checked here rather than at scheduling time so
        // that plugging in — or pulling out — headphones right before speaking counts.
        if skipMuteWithHeadphones, isOutputOnHeadphones() {
            state.withLock { state in
                state.didMuteAudio = false
                state.wasAudioMutedBeforeRecording = false
            }
            return false
        }

        if isSystemAudioMuted() {
            // Already muted before we got here — remember that, so the unmute path
            // does not un-mute something the user muted themselves.
            state.withLock { state in
                state.wasAudioMutedBeforeRecording = !state.didMuteAudio
                if !state.didMuteAudio {
                    state.didMuteAudio = false
                }
            }
            return true
        }

        state.withLock { $0.wasAudioMutedBeforeRecording = false }

        let success = setSystemMuted(true)
        let raced = state.withLock { state -> Bool in
            // Only claim mute ownership while this generation is still current.
            guard state.generation == generation else { return success }
            state.didMuteAudio = success
            return false
        }
        if raced {
            // Muted after a cancel landed — undo it rather than stranding the output.
            _ = setSystemMuted(false)
        }
        return success
    }

    func unmuteSystemAudio() async {
        guard isSystemMuteEnabled else { return }

        let delay = audioResumptionDelay
        let (shouldUnmute, myGeneration) = state.withLock { state -> (Bool, Int) in
            state.muteTask?.cancel()
            state.muteTask = nil
            let shouldUnmute = state.didMuteAudio && !state.wasAudioMutedBeforeRecording
            return (shouldUnmute, state.nextGeneration())
        }

        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard let self, !Task.isCancelled else { return }
            guard self.state.withLock({ $0.generation == myGeneration }) else { return }

            if shouldUnmute {
                _ = self.setSystemMuted(false)
            }
            self.state.withLock { $0.didMuteAudio = false }
        }

        state.withLock { $0.unmuteTask = task }
        await task.value
    }

    /// Immediately releases only a mute owned by Zerm. User-initiated mute state is preserved.
    private func restoreOutputForMeeting() {
        let shouldUnmute = state.withLock { state -> Bool in
            state.muteTask?.cancel()
            state.muteTask = nil
            state.unmuteTask?.cancel()
            state.unmuteTask = nil
            _ = state.nextGeneration()
            let shouldUnmute = state.didMuteAudio && !state.wasAudioMutedBeforeRecording
            state.didMuteAudio = false
            state.wasAudioMutedBeforeRecording = false
            return shouldUnmute
        }
        if shouldUnmute {
            _ = setSystemMuted(false)
        }
    }

    /// True when the current default output is Bluetooth, the built-in headphone jack, or a
    /// USB device that also exposes an input stream (a headset). Anything else — internal or
    /// external speakers, output-only USB DACs, HDMI, AirPlay — is assumed to play into the room.
    func isOutputOnHeadphones() -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }
        return AudioOutputRoute.currentConsideringUserConfirmation(for: deviceID) == .headphones
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        AudioObjectProperty.uint32(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
    }

    // Returns the mute elements that are currently readable on the given device
    // (element 0 = master, 1/2 = per-channel for stereo devices).
    // Some USB DACs (Topping, SMSL, etc.) only expose per-channel mute properties,
    // which is why the previous master-only check silently failed on those devices
    // while leaving audio stuck in muted state (VoiceInk #640).
    private func muteableElements(for deviceID: AudioDeviceID) -> [UInt32] {
        // Probe elements: master (0) + first 8 channels
        let candidates: [UInt32] = (0...8).map { UInt32($0) }
        return candidates.filter { element in
            AudioObjectProperty.isSettable(
                deviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioDevicePropertyScopeOutput,
                element: element
            )
        }
    }

    private func isSystemAudioMuted() -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }

        // Check any mutable element — if the master element is muted, or every
        // channel is muted, consider the device muted.
        return muteableElements(for: deviceID).contains { element in
            AudioObjectProperty.uint32(
                deviceID,
                selector: kAudioDevicePropertyMute,
                scope: kAudioDevicePropertyScopeOutput,
                element: element
            ).map { $0 != 0 } ?? false
        }
    }

    private func setSystemMuted(_ muted: Bool) -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }

        let elements = muteableElements(for: deviceID)
        guard !elements.isEmpty else { return false }

        var muteValue: UInt32 = muted ? 1 : 0
        let propertySize = UInt32(MemoryLayout<UInt32>.size)
        var anySuccess = false

        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, propertySize, &muteValue) == noErr {
                anySuccess = true
            }
        }
        return anySuccess
    }
}
