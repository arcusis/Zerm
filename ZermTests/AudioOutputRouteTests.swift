import CoreAudio
import Testing
@testable import Zerm

struct AudioOutputRouteTests {

    private let headphoneJack: UInt32 = 0x6864_706E // 'hdpn'
    private let internalSpeaker: UInt32 = 0x6973_706B // 'ispk'

    @Test func bluetoothCountsAsHeadphones() {
        // AirPods and every other BT headset report 'blue'/'blea' with no data source.
        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeBluetooth,
            builtInDataSource: nil
        ) == .headphones)

        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeBluetoothLE,
            builtInDataSource: nil
        ) == .headphones)
    }

    @Test func builtInSplitsOnDataSource() {
        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            builtInDataSource: headphoneJack
        ) == .headphones)

        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            builtInDataSource: internalSpeaker
        ) == .speakers)
    }

    @Test func builtInWithUnreadableDataSourceStaysMuted() {
        // Failing to read the data source must not be mistaken for headphones —
        // that would let the internal speaker bleed into the transcript.
        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            builtInDataSource: nil
        ) == .speakers)
    }

    @Test func roomPlayingTransportsStayMuted() {
        let roomTransports: [UInt32] = [
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeUnknown,
        ]

        for transport in roomTransports {
            #expect(AudioOutputRoute.classify(
                transportType: transport,
                builtInDataSource: nil
            ) == .speakers)
        }
    }

    @Test func dataSourceIsIgnoredOffBuiltIn() {
        // A USB DAC that happens to report 'hdpn' must not flip the verdict —
        // only the built-in device's data source is trusted.
        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeUSB,
            builtInDataSource: headphoneJack
        ) == .speakers)
    }
}
