import CoreAudio
import Foundation
import os

/// Whether the current output route can acoustically leak back into the microphone.
///
/// The only reason Zerm mutes system audio while recording is speaker bleed —
/// music or a call coming out of speakers, back in through the mic, and landing
/// in the transcript as speech. On headphones that path does not exist, so the
/// mute is pure cost.
enum AudioOutputRoute: Equatable {
    /// Sealed to the user's ears — nothing reaches the microphone.
    case headphones
    /// Anything that plays into the room, or that we cannot positively identify.
    case speakers

    /// `'hdpn'` — the data source the built-in output reports for the headphone jack.
    private static let headphoneJackDataSource: UInt32 = 0x6864_706E
    /// Process-only confirmations. They deliberately never enter UserDefaults: the same built-in
    /// jack and device UID can later have powered speakers connected to it.
    private static let analogHeadphoneConfirmations = OSAllocatedUnfairLock(
        initialState: Set<AudioDeviceID>()
    )

    struct Evidence: Equatable {
        let transportType: UInt32
        let builtInDataSource: UInt32?
        let outputTerminalTypes: Set<UInt32>
        let hasRelatedInputDevice: Bool
    }

    /// Classifies a route from its CoreAudio transport type and, for built-in
    /// output, the selected data source. Pure, so it can be tested without hardware.
    ///
    /// Unrecognised transports (HDMI, AirPlay, aggregates) and output-only USB devices are
    /// treated as speakers: a false "headphones" verdict silently lets audio bleed into
    /// transcripts, while a false "speakers" verdict only mutes when it need not.
    static func classify(_ evidence: Evidence) -> AudioOutputRoute {
        if evidence.transportType == kAudioDeviceTransportTypeBuiltIn,
           evidence.builtInDataSource == headphoneJackDataSource {
            // macOS exposes both wired headphones and analogue powered speakers through this
            // one data source and provides no public physical-device distinction. Stay
            // fail-closed until the user explicitly confirms headphones for this device.
            return .speakers
        }

        // Stream terminal metadata is the strongest public signal. In particular, Bluetooth
        // transport alone is not sufficient: Bluetooth speakers report the same transport as
        // AirPods and must remain unsafe during a meeting.
        let roomTerminals: Set<UInt32> = [
            kAudioStreamTerminalTypeLine,
            kAudioStreamTerminalTypeDigitalAudioInterface,
            kAudioStreamTerminalTypeSpeaker,
            kAudioStreamTerminalTypeLFESpeaker,
            kAudioStreamTerminalTypeReceiverSpeaker,
            kAudioStreamTerminalTypeHDMI,
            kAudioStreamTerminalTypeDisplayPort,
        ]
        if !evidence.outputTerminalTypes.isDisjoint(with: roomTerminals) {
            return .speakers
        }
        if evidence.outputTerminalTypes.contains(kAudioStreamTerminalTypeHeadphones) {
            return .headphones
        }

        switch evidence.transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return .speakers
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB:
            // A related input endpoint is conservative evidence of a headset even when macOS
            // exposes its microphone and output as separate AudioDevice objects. Output-only
            // Bluetooth speakers and USB DACs stay unsafe.
            return evidence.hasRelatedInputDevice ? .headphones : .speakers
        default:
            return .speakers
        }
    }

    /// Classifies the given output device by querying CoreAudio.
    static func current(for deviceID: AudioDeviceID) -> AudioOutputRoute {
        guard let transport = transportType(of: deviceID) else { return .speakers }
        return classify(.init(
            transportType: transport,
            builtInDataSource: transport == kAudioDeviceTransportTypeBuiltIn
                ? outputDataSource(of: deviceID)
                : nil,
            outputTerminalTypes: outputTerminalTypes(of: deviceID),
            hasRelatedInputDevice: hasInputStreams(deviceID)
                || relatedDevices(of: deviceID).contains(where: hasInputStreams)
        ))
    }

    static func currentConsideringUserConfirmation(for deviceID: AudioDeviceID) -> AudioOutputRoute {
        resolveAmbiguousAnalogRoute(
            classifiedRoute: current(for: deviceID),
            isAmbiguous: isAmbiguousAnalogOutput(deviceID),
            userConfirmedHeadphones: hasSessionHeadphoneConfirmation(for: deviceID)
        )
    }

    /// The built-in analog jack is unsafe unless the user positively identifies it as headphones.
    /// Kept pure so the fail-closed policy can be verified without depending on CoreAudio hardware.
    static func resolveAmbiguousAnalogRoute(
        classifiedRoute: AudioOutputRoute,
        isAmbiguous: Bool,
        userConfirmedHeadphones: Bool
    ) -> AudioOutputRoute {
        guard isAmbiguous else { return classifiedRoute }
        return userConfirmedHeadphones ? .headphones : .speakers
    }

    /// The built-in analog jack reports the same public CoreAudio data source for wired
    /// headphones and powered speakers. Callers can offer an explicit, per-device headphone
    /// confirmation; without one this route remains classified as speakers.
    static func isAmbiguousAnalogOutput(_ deviceID: AudioDeviceID) -> Bool {
        transportType(of: deviceID) == kAudioDeviceTransportTypeBuiltIn
            && outputDataSource(of: deviceID) == headphoneJackDataSource
    }

    static func hasSessionHeadphoneConfirmation(for deviceID: AudioDeviceID) -> Bool {
        analogHeadphoneConfirmations.withLock { $0.contains(deviceID) }
    }

    static func setSessionHeadphoneConfirmation(_ confirmed: Bool, for deviceID: AudioDeviceID) {
        analogHeadphoneConfirmations.withLock { confirmations in
            if confirmed {
                confirmations.insert(deviceID)
            } else {
                confirmations.remove(deviceID)
            }
        }
    }

    static func clearSessionHeadphoneConfirmations() {
        analogHeadphoneConfirmations.withLock { $0.removeAll() }
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

    /// USB headsets normally expose input and output streams on the same CoreAudio device.
    /// Reading only the byte count avoids allocating or touching the real-time audio path.
    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectProperty.address(
            kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeInput
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func outputTerminalTypes(of deviceID: AudioDeviceID) -> Set<UInt32> {
        Set(streams(of: deviceID, scope: kAudioDevicePropertyScopeOutput).compactMap { streamID in
            AudioObjectProperty.uint32(streamID, selector: kAudioStreamPropertyTerminalType)
        })
    }

    private static func streams(
        of deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> [AudioStreamID] {
        readObjectIDs(
            from: deviceID,
            selector: kAudioDevicePropertyStreams,
            scope: scope
        )
    }

    private static func relatedDevices(of deviceID: AudioDeviceID) -> [AudioDeviceID] {
        readObjectIDs(
            from: deviceID,
            selector: kAudioDevicePropertyRelatedDevices,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func readObjectIDs(
        from objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectProperty.address(selector, scope: scope)
        guard AudioObjectHasProperty(objectID, &address) else { return [] }

        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &byteCount) == noErr,
              byteCount >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }

        var values = [AudioObjectID](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, bytes.baseAddress!)
        }
        guard status == noErr else {
            return []
        }
        return values
    }
}
