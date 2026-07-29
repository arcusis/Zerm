import CoreAudio
import Foundation

/// Typed, memory-safe reads of CoreAudio object properties.
///
/// Replaces three near-identical copies of the `AudioObjectGetPropertyData`
/// boilerplate that had drifted apart. The string reader matters most: CoreAudio
/// hands back a **+1 retained** `CFStringRef`, and the previous code passed
/// `&property` on an ARC-managed `CFString?`. That writes an unbalanced retain
/// into a variable ARC also releases, so the string was over-released — and the
/// compiler warned that forming a raw pointer to an `Optional` holding an object
/// reference is not sound in the first place. `Unmanaged` makes the ownership
/// transfer explicit.
enum AudioObjectProperty {

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a CFString-valued property, consuming the +1 reference CoreAudio returns.
    static func string(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> String? {
        guard objectID != 0 else { return nil }

        var address = address(selector, scope: scope, element: element)
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var unmanaged: Unmanaged<CFString>?

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, &unmanaged)
        guard status == noErr, let unmanaged else { return nil }

        return unmanaged.takeRetainedValue() as String
    }

    /// Reads a fixed-width integer property (transport type, data source, mute, …).
    static func uint32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> UInt32? {
        guard objectID != 0 else { return nil }

        var address = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(objectID, &address) else { return nil }

        var value: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, &value)
        guard status == noErr else { return nil }

        return value
    }

    /// True when the property exists on the object *and* can be written.
    static func isSettable(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(objectID, &address) else { return false }

        var isSettable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(objectID, &address, &isSettable) == noErr && isSettable.boolValue
    }
}
