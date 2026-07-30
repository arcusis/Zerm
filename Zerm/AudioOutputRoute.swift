import CoreAudio
import Foundation

/// Whether the current output route can acoustically leak back into the microphone.
///
/// The only reason Zerm mutes system audio while recording is speaker bleed —
/// music or a call coming out of speakers, back in through the mic, and landing
/// in the transcript as speech. On headphones that path does not exist, so the
/// mute is pure cost.
enum AudioOutputRoute {
    /// Sealed to the user's ears — nothing reaches the microphone.
    case headphones
    /// Anything that plays into the room, or that we cannot positively identify.
    case speakers

    /// `'hdpn'` — the data source the built-in output reports for the headphone jack.
    private static let headphoneJackDataSource: UInt32 = 0x6864_706E

    /// Classifies a route from its CoreAudio transport type and, for built-in
    /// output, the selected data source. Pure, so it can be tested without hardware.
    ///
    /// Unrecognised transports (USB DACs, HDMI, AirPlay, aggregates) are treated as
    /// speakers: a false "headphones" verdict silently lets audio bleed into
    /// transcripts, while a false "speakers" verdict only mutes when it need not.
    static func classify(transportType: UInt32, builtInDataSource: UInt32?) -> AudioOutputRoute {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        case kAudioDeviceTransportTypeBuiltIn:
            return builtInDataSource == headphoneJackDataSource ? .headphones : .speakers
        default:
            return .speakers
        }
    }

    /// Classifies the given output device by querying CoreAudio.
    static func current(for deviceID: AudioDeviceID) -> AudioOutputRoute {
        guard let transport = transportType(of: deviceID) else { return .speakers }
        return classify(
            transportType: transport,
            builtInDataSource: transport == kAudioDeviceTransportTypeBuiltIn
                ? outputDataSource(of: deviceID)
                : nil
        )
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        AudioObjectProperty.uint32(deviceID, selector: kAudioDevicePropertyTransportType)
    }

    private static func outputDataSource(of deviceID: AudioDeviceID) -> UInt32? {
        AudioObjectProperty.uint32(
            deviceID,
            selector: kAudioDevicePropertyDataSource,
            scope: kAudioDevicePropertyScopeOutput
        )
    }
}
