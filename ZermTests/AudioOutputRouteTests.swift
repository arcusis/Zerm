import CoreAudio
import Testing
@testable import Zerm

struct AudioOutputRouteTests {

    private let headphoneJack: UInt32 = 0x6864_706E // 'hdpn'
    private let internalSpeaker: UInt32 = 0x6973_706B // 'ispk'

    @Test func bluetoothNeedsHeadsetEvidence() {
        #expect(AudioOutputRoute.classify(.init(
            transportType: kAudioDeviceTransportTypeBluetooth,
            builtInDataSource: nil,
            outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones],
            hasRelatedInputDevice: true
        )) == .headphones)

        #expect(AudioOutputRoute.classify(.init(
            transportType: kAudioDeviceTransportTypeBluetoothLE,
            builtInDataSource: nil,
            outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker],
            hasRelatedInputDevice: false
        )) == .speakers)
    }

    @Test func ambiguousBuiltInJackFailsClosedUntilHeadphonesAreConfirmed() {
        #expect(AudioOutputRoute.classify(.init(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            builtInDataSource: headphoneJack,
            outputTerminalTypes: [],
            hasRelatedInputDevice: false
        )) == .speakers)

        #expect(AudioOutputRoute.resolveAmbiguousAnalogRoute(
            classifiedRoute: .speakers,
            isAmbiguous: true,
            userConfirmedHeadphones: false
        ) == .speakers)

        #expect(AudioOutputRoute.resolveAmbiguousAnalogRoute(
            classifiedRoute: .speakers,
            isAmbiguous: true,
            userConfirmedHeadphones: true
        ) == .headphones)

        #expect(AudioOutputRoute.classify(.init(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            builtInDataSource: internalSpeaker,
            outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker],
            hasRelatedInputDevice: true
        )) == .speakers)
    }

    @Test func headphoneConfirmationCannotOverrideAnUnambiguousSpeakerRoute() {
        #expect(AudioOutputRoute.resolveAmbiguousAnalogRoute(
            classifiedRoute: .speakers,
            isAmbiguous: false,
            userConfirmedHeadphones: true
        ) == .speakers)
    }

    @Test func analogHeadphoneConfirmationIsRevocableProcessState() {
        let syntheticDevice = AudioDeviceID.max - 1
        AudioOutputRoute.setSessionHeadphoneConfirmation(false, for: syntheticDevice)
        #expect(!AudioOutputRoute.hasSessionHeadphoneConfirmation(for: syntheticDevice))

        AudioOutputRoute.setSessionHeadphoneConfirmation(true, for: syntheticDevice)
        #expect(AudioOutputRoute.hasSessionHeadphoneConfirmation(for: syntheticDevice))

        AudioOutputRoute.setSessionHeadphoneConfirmation(false, for: syntheticDevice)
        #expect(!AudioOutputRoute.hasSessionHeadphoneConfirmation(for: syntheticDevice))
    }

    @Test func builtInWithUnreadableDataSourceStaysMuted() {
        // Failing to read the data source must not be mistaken for headphones —
        // that would let the internal speaker bleed into the transcript.
        #expect(AudioOutputRoute.classify(.init(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            builtInDataSource: nil,
            outputTerminalTypes: [],
            hasRelatedInputDevice: false
        )) == .speakers)
    }

    @Test func roomPlayingTransportsStayMuted() {
        let roomTransports: [UInt32] = [
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeUnknown,
        ]

        for transport in roomTransports {
            #expect(AudioOutputRoute.classify(.init(
                transportType: transport,
                builtInDataSource: nil,
                outputTerminalTypes: [],
                hasRelatedInputDevice: false
            )) == .speakers)
        }
    }

    @Test func usbHeadsetRequiresInputStream() {
        #expect(AudioOutputRoute.classify(.init(
            transportType: kAudioDeviceTransportTypeUSB,
            builtInDataSource: nil,
            outputTerminalTypes: [],
            hasRelatedInputDevice: true
        )) == .headphones)

        // Output-only USB DACs and speakers remain unsafe during meetings.
        #expect(AudioOutputRoute.classify(.init(
            transportType: kAudioDeviceTransportTypeUSB,
            builtInDataSource: headphoneJack,
            outputTerminalTypes: [],
            hasRelatedInputDevice: false
        )) == .speakers)
    }
}
