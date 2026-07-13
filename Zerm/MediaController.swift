import Foundation
import CoreAudio

final class MediaController: ObservableObject {

    static let shared = MediaController()

    private var didMuteAudio = false
    private var wasAudioMutedBeforeRecording = false
    private var unmuteTask: Task<Void, Never>?
    private var muteTask: Task<Void, Never>?
    private var muteGeneration: Int = 0
    private let lock = NSLock()

    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet { UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled") }
    }

    @Published var audioResumptionDelay: Double = UserDefaults.standard.double(forKey: "audioResumptionDelay") {
        didSet { UserDefaults.standard.set(audioResumptionDelay, forKey: "audioResumptionDelay") }
    }

    private init() {}

    /// Cancels any deferred mute so a quick cancel cannot leave the system muted
    /// after a late start-sound completion. Call from stop/cancel paths.
    func cancelPendingMute() {
        lock.lock()
        muteTask?.cancel()
        muteTask = nil
        muteGeneration += 1
        lock.unlock()
    }

    /// Mutes system audio immediately (decoupled from start-sound playback).
    func muteSystemAudio() async -> Bool {
        guard isSystemMuteEnabled else { return false }

        lock.lock()
        unmuteTask?.cancel()
        unmuteTask = nil
        muteTask?.cancel()
        muteTask = nil
        muteGeneration += 1
        let myGeneration = muteGeneration
        lock.unlock()

        return await performMute(generation: myGeneration)
    }

    /// Schedules mute after `delay` seconds, cancellable via `cancelPendingMute` / `unmuteSystemAudio`.
    func scheduleMuteSystemAudio(after delay: TimeInterval = 0) {
        guard isSystemMuteEnabled else { return }

        lock.lock()
        unmuteTask?.cancel()
        unmuteTask = nil
        muteTask?.cancel()
        muteGeneration += 1
        let myGeneration = muteGeneration
        lock.unlock()

        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            _ = await self.performMute(generation: myGeneration)
        }
        lock.lock()
        muteTask = task
        lock.unlock()
    }

    private func performMute(generation: Int) async -> Bool {
        lock.lock()
        let stillValid = muteGeneration == generation
        lock.unlock()
        guard stillValid else { return false }

        let currentlyMuted = isSystemAudioMuted()

        if currentlyMuted {
            lock.lock()
            if didMuteAudio {
                wasAudioMutedBeforeRecording = false
            } else {
                wasAudioMutedBeforeRecording = true
                didMuteAudio = false
            }
            lock.unlock()
            return true
        }

        lock.lock()
        wasAudioMutedBeforeRecording = false
        lock.unlock()
        let success = setSystemMuted(true)
        lock.lock()
        // Only commit mute ownership if this generation is still current
        if muteGeneration == generation {
            didMuteAudio = success
        } else if success {
            // We muted after cancel — reverse it immediately
            _ = setSystemMuted(false)
        }
        lock.unlock()
        return success
    }

    func unmuteSystemAudio() async {
        guard isSystemMuteEnabled else { return }

        lock.lock()
        muteTask?.cancel()
        muteTask = nil
        muteGeneration += 1
        let delay = audioResumptionDelay
        let shouldUnmute = didMuteAudio && !wasAudioMutedBeforeRecording
        let myGeneration = muteGeneration
        lock.unlock()

        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            self.lock.lock()
            let stillValid = self.muteGeneration == myGeneration
            let doUnmute = shouldUnmute
            self.lock.unlock()
            guard stillValid else { return }

            if doUnmute {
                _ = self.setSystemMuted(false)
            }

            self.lock.lock()
            self.didMuteAudio = false
            self.lock.unlock()
        }

        lock.lock()
        unmuteTask = task
        lock.unlock()
        await task.value
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
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
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &address) else { return false }
            var isSettable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr && isSettable.boolValue
        }
    }

    private func isSystemAudioMuted() -> Bool {
        guard let deviceID = getDefaultOutputDevice() else { return false }

        // Check any mutable element — if the master element is muted, or every
        // channel is muted, consider the device muted.
        for element in muteableElements(for: deviceID) {
            var muted: UInt32 = 0
            var propertySize = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &muted) == noErr && muted != 0 {
                return true
            }
        }
        return false
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
