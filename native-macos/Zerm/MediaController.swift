import Foundation
import CoreAudio

final class MediaController: ObservableObject {

    static let shared = MediaController()

    private var didMuteAudio = false
    private var wasAudioMutedBeforeRecording = false
    private var unmuteTask: Task<Void, Never>?
    private var muteGeneration: Int = 0

    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet { UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled") }
    }

    @Published var audioResumptionDelay: Double = UserDefaults.standard.double(forKey: "audioResumptionDelay") {
        didSet { UserDefaults.standard.set(audioResumptionDelay, forKey: "audioResumptionDelay") }
    }

    private init() {}

    func muteSystemAudio() async -> Bool {
        guard isSystemMuteEnabled else { return false }

        unmuteTask?.cancel()
        unmuteTask = nil
        muteGeneration += 1

        let currentlyMuted = isSystemAudioMuted()

        if currentlyMuted {
            if didMuteAudio {
                // We muted it previously, stay responsible for unmuting
                wasAudioMutedBeforeRecording = false
            } else {
                // User muted it, don't unmute when done
                wasAudioMutedBeforeRecording = true
                didMuteAudio = false
            }
            return true
        }

        wasAudioMutedBeforeRecording = false
        let success = setSystemMuted(true)
        didMuteAudio = success
        return success
    }

    func unmuteSystemAudio() async {
        guard isSystemMuteEnabled else { return }

        let delay = audioResumptionDelay
        let shouldUnmute = didMuteAudio && !wasAudioMutedBeforeRecording
        let myGeneration = muteGeneration

        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            guard self.muteGeneration == myGeneration else { return }

            if shouldUnmute {
                _ = self.setSystemMuted(false)
            }

            self.didMuteAudio = false
        }

        unmuteTask = task
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
