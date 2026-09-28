import CoreAudio

/// Read-only facts about an audio device, for logging and availability checks.
enum AudioDeviceInfo {
    static func name(of deviceID: AudioDeviceID) -> String? {
        AudioObjectProperty.string(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    static func uid(of deviceID: AudioDeviceID) -> String? {
        AudioObjectProperty.string(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func manufacturer(of deviceID: AudioDeviceID) -> String? {
        AudioObjectProperty.string(deviceID, selector: kAudioDevicePropertyDeviceManufacturerCFString)
    }

    static func bufferFrameSize(of deviceID: AudioDeviceID) -> UInt32? {
        AudioObjectProperty.uint32(deviceID, selector: kAudioDevicePropertyBufferFrameSize)
    }

    /// Whether the device is still present (`kAudioDevicePropertyDeviceIsAlive`).
    static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        AudioObjectProperty.uint32(deviceID, selector: kAudioDevicePropertyDeviceIsAlive) == 1
    }

    static func transportName(of deviceID: AudioDeviceID) -> String {
        guard let transportType = AudioObjectProperty.uint32(deviceID, selector: kAudioDevicePropertyTransportType) else {
            return "Unknown"
        }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        default: return "Other (\(transportType))"
        }
    }
}
