import CoreAudio

enum AudioInputDeviceResolver {
    struct Device: Equatable {
        let id: AudioDeviceID
        let transportType: UInt32?
    }

    static func resolve(
        selectedDeviceID: AudioDeviceID,
        availableDevices: [Device],
        preserveBluetoothMediaQuality: Bool,
        isBuiltInMicrophoneUsable: Bool
    ) -> AudioDeviceID {
        guard preserveBluetoothMediaQuality,
              let selectedDevice = availableDevices.first(where: { $0.id == selectedDeviceID }),
              isBluetooth(selectedDevice.transportType) else {
            return selectedDeviceID
        }

        // With the lid closed the built-in microphone stays listed but records silence.
        let candidates = availableDevices.filter {
            isBuiltInMicrophoneUsable || $0.transportType != kAudioDeviceTransportTypeBuiltIn
        }

        if let builtIn = candidates.first(where: {
            $0.transportType == kAudioDeviceTransportTypeBuiltIn
        }) {
            return builtIn.id
        }

        return candidates.first(where: {
            guard let transportType = $0.transportType else { return false }
            return !isBluetooth(transportType)
        })?.id ?? selectedDeviceID
    }

    private static func isBluetooth(_ transportType: UInt32?) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}
