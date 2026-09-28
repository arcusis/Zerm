import CoreAudio
import Testing
@testable import Zerm

struct AudioInputDeviceResolverTests {
    private let bluetooth = AudioInputDeviceResolver.Device(
        id: 10,
        transportType: kAudioDeviceTransportTypeBluetooth
    )
    private let bluetoothLE = AudioInputDeviceResolver.Device(
        id: 11,
        transportType: kAudioDeviceTransportTypeBluetoothLE
    )
    private let builtIn = AudioInputDeviceResolver.Device(
        id: 20,
        transportType: kAudioDeviceTransportTypeBuiltIn
    )
    private let usb = AudioInputDeviceResolver.Device(
        id: 30,
        transportType: kAudioDeviceTransportTypeUSB
    )

    @Test func bluetoothInputUsesBuiltInMicrophoneFirst() {
        #expect(resolve(selected: bluetooth.id, devices: [bluetooth, usb, builtIn]) == builtIn.id)
    }

    @Test func bluetoothLEInputUsesAnotherNonBluetoothMicrophone() {
        #expect(resolve(selected: bluetoothLE.id, devices: [bluetoothLE, usb]) == usb.id)
    }

    @Test func nonBluetoothSelectionRemainsUnchanged() {
        #expect(resolve(selected: usb.id, devices: [bluetooth, builtIn, usb]) == usb.id)
    }

    @Test func disabledProtectionKeepsBluetoothSelection() {
        #expect(AudioInputDeviceResolver.resolve(
            selectedDeviceID: bluetooth.id,
            availableDevices: [bluetooth, builtIn],
            preserveBluetoothMediaQuality: false,
            isBuiltInMicrophoneUsable: true
        ) == bluetooth.id)
    }

    @Test func closedLidSkipsSilentBuiltInMicrophone() {
        #expect(resolve(selected: bluetooth.id, devices: [bluetooth, builtIn, usb], builtInUsable: false) == usb.id)
    }

    @Test func closedLidWithoutAlternativeKeepsBluetooth() {
        #expect(resolve(selected: bluetooth.id, devices: [bluetooth, builtIn], builtInUsable: false) == bluetooth.id)
    }

    @Test func bluetoothRemainsWhenNoAlternativeExists() {
        #expect(resolve(selected: bluetooth.id, devices: [bluetooth, bluetoothLE]) == bluetooth.id)
    }

    private func resolve(
        selected: AudioDeviceID,
        devices: [AudioInputDeviceResolver.Device],
        builtInUsable: Bool = true
    ) -> AudioDeviceID {
        AudioInputDeviceResolver.resolve(
            selectedDeviceID: selected,
            availableDevices: devices,
            preserveBluetoothMediaQuality: true,
            isBuiltInMicrophoneUsable: builtInUsable
        )
    }
}
