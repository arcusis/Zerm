import Combine
import CoreAudio
import Foundation
import os

/// Process-wide observation of the default output route.
///
/// Listening to only the default-device property is insufficient: inserting wired headphones
/// can change the built-in device's data source without changing its device ID. This monitor
/// therefore rebinds a data-source listener whenever the default device changes.
@MainActor
final class AudioOutputRouteMonitor: ObservableObject {
    static let shared = AudioOutputRouteMonitor()

    @Published private(set) var route: AudioOutputRoute
    @Published private(set) var isAmbiguousAnalogOutput: Bool
    @Published private(set) var confirmsAmbiguousAnalogHeadphones: Bool

    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "AudioOutputRouteMonitor")
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var monitoredDevice: AudioDeviceID?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private init() {
        let device = Self.defaultOutputDevice()
        monitoredDevice = device
        let ambiguous = device.map { AudioOutputRoute.isAmbiguousAnalogOutput($0) } ?? false
        let confirmation = device.map {
            AudioOutputRoute.hasSessionHeadphoneConfirmation(for: $0)
        } ?? false
        isAmbiguousAnalogOutput = ambiguous
        confirmsAmbiguousAnalogHeadphones = ambiguous && confirmation
        route = device.map {
            AudioOutputRoute.currentConsideringUserConfirmation(for: $0)
        } ?? .speakers
        installSystemListener()
        installDeviceListListener()
        installDeviceListener(for: device)
    }

    private func installDeviceListListener() {
        var address = AudioObjectProperty.address(kAudioHardwarePropertyDevices)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshRoute() }
        }
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &address, .main, listener)
        guard status == noErr else {
            logger.error("Could not monitor related audio-device changes (status \(status, privacy: .public))")
            return
        }
        deviceListListener = listener
    }

    private func installSystemListener() {
        var address = AudioObjectProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.defaultOutputDeviceChanged()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(systemObject, &address, .main, listener)
        guard status == noErr else {
            logger.error("Could not monitor the default audio output (status \(status, privacy: .public))")
            return
        }
        systemListener = listener
    }

    private func defaultOutputDeviceChanged() {
        let device = Self.defaultOutputDevice()
        guard device != monitoredDevice else {
            AudioOutputRoute.clearSessionHeadphoneConfirmations()
            refreshRoute()
            return
        }
        removeDeviceListener()
        AudioOutputRoute.clearSessionHeadphoneConfirmations()
        monitoredDevice = device
        installDeviceListener(for: device)
        refreshRoute()
    }

    private func installDeviceListener(for device: AudioDeviceID?) {
        guard let device else { return }
        var address = AudioObjectProperty.address(
            kAudioDevicePropertyDataSource,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard AudioObjectHasProperty(device, &address) else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.outputDataSourceChanged()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        guard status == noErr else {
            logger.error("Could not monitor output data-source changes (status \(status, privacy: .public))")
            return
        }
        deviceListener = listener
    }

    private func outputDataSourceChanged() {
        // Treat every data-source notification as a new physical connection. CoreAudio may
        // coalesce a fast headphones-to-speakers swap back to the same public `hdpn` value.
        AudioOutputRoute.clearSessionHeadphoneConfirmations()
        refreshRoute()
    }

    private func removeDeviceListener() {
        guard let device = monitoredDevice, let listener = deviceListener else { return }
        var address = AudioObjectProperty.address(
            kAudioDevicePropertyDataSource,
            scope: kAudioDevicePropertyScopeOutput
        )
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
        deviceListener = nil
    }

    private func refreshRoute() {
        if Self.defaultOutputDevice() != monitoredDevice {
            defaultOutputDeviceChanged()
            return
        }
        let ambiguous = monitoredDevice.map { AudioOutputRoute.isAmbiguousAnalogOutput($0) } ?? false
        if !ambiguous, let monitoredDevice {
            // Unplugging the jack or changing its data source invalidates the physical claim.
            AudioOutputRoute.setSessionHeadphoneConfirmation(false, for: monitoredDevice)
        }
        let confirmation = monitoredDevice.map {
            AudioOutputRoute.hasSessionHeadphoneConfirmation(for: $0)
        } ?? false
        isAmbiguousAnalogOutput = ambiguous
        confirmsAmbiguousAnalogHeadphones = ambiguous && confirmation
        let updated = monitoredDevice.map {
            AudioOutputRoute.currentConsideringUserConfirmation(for: $0)
        } ?? .speakers
        if route != updated {
            route = updated
        }
    }

    /// Confirms headphones only for this process and connection cycle. A default-device or
    /// data-source change clears the claim, as does quitting Zerm.
    func setConfirmsAmbiguousAnalogHeadphones(_ confirmed: Bool) {
        guard let device = monitoredDevice, isAmbiguousAnalogOutput else { return }
        AudioOutputRoute.setSessionHeadphoneConfirmation(confirmed, for: device)
        refreshRoute()
    }

    /// Invalidates an ambiguous-jack claim at a new safety boundary, such as starting a meeting
    /// or ending a Read Aloud attempt. Known Bluetooth/USB/wired routes are unaffected.
    func clearAmbiguousAnalogHeadphoneConfirmation() {
        guard let device = monitoredDevice, isAmbiguousAnalogOutput else { return }
        AudioOutputRoute.setSessionHeadphoneConfirmation(false, for: device)
        refreshRoute()
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        AudioObjectProperty.uint32(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
    }
}
