import CoreAudio
import Foundation

/// One enumerable audio input device. `id` (AudioDeviceID) is valid only for
/// the current process lifetime — it can change across reboots and even across
/// device hot-plugs — so persist `uid` (the stable Core Audio DeviceUID) and
/// resolve it back to an `id` at start time.
struct AudioInputDevice: Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Core Audio device enumeration helpers. AVAudioEngine's `inputNode` always
/// binds to the system default input; to point it at a specific device we need
/// the underlying `AudioDeviceID`, which we look up here.
enum AudioDevices {
    /// All devices that currently expose at least one input stream channel,
    /// sorted by name for a stable menu order. Cheap enough to call every
    /// time the menu opens.
    static func inputDevices() -> [AudioInputDevice] {
        let ids = allDeviceIDs()
        var devices: [AudioInputDevice] = []
        devices.reserveCapacity(ids.count)
        for id in ids {
            guard inputChannelCount(id) > 0 else { continue }
            guard let uid = deviceUID(id), let name = deviceName(id) else { continue }
            devices.append(AudioInputDevice(id: id, uid: uid, name: name))
        }
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return devices
    }

    /// The system default input device, or nil if Core Audio reports none.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &id
        )
        return status == noErr ? id : nil
    }

    /// Resolve a stable DeviceUID back to the current `AudioDeviceID`. Returns
    /// nil when the device is no longer present (unplugged, driver unloaded) —
    /// callers fall back to the system default in that case.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for device in inputDevices() where device.uid == uid {
            return device.id
        }
        return nil
    }

    /// Temporarily set the system default input device. Used by `MicRecorder`
    /// to point `AVAudioEngine.inputNode` (which always binds to the system
    /// default) at a specific device — `setDeviceID` on the underlying AU is
    /// unreliable and often produces silence. Returns the previous default so
    /// the caller can restore it when recording stops.
    @discardableResult
    static func setDefaultInputDevice(_ id: AudioDeviceID) -> AudioDeviceID? {
        let previous = defaultInputDeviceID()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newID = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &newID
        )
        if status != noErr {
            FileHandle.standardError.write(Data(
                "warning: couldn't set default input device to \(id) (status \(status))\n".utf8
            ))
            return nil
        }
        return previous
    }

    /// Restore the system default input device to a previously saved id.
    /// No-op if `id` is nil (e.g. the original default couldn't be read).
    static func restoreDefaultInputDevice(_ id: AudioDeviceID?) {
        guard let id else { return }
        setDefaultInputDevice(id)
    }

    /// Human-readable name for a device id, for logging. nil on failure.
    static func deviceName(forID id: AudioDeviceID) -> String? {
        deviceName(id)
    }

    // MARK: - Core Audio property reads

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        )
        return getStatus == noErr ? ids : []
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 1)
        defer { buffer.deallocate() }
        let getStatus = AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer)
        guard getStatus == noErr else { return 0 }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self).pointee
        return list.mNumberBuffers > 0 ? list.mBuffers.mNumberChannels : 0
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        // DeviceUID is a CFString property, not a C-string like DeviceName,
        // so it needs a dedicated reader. withUnsafeMutablePointer avoids the
        // "forming UnsafeMutableRawPointer to Optional<CFString>" warning.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        readStringProperty(id, selector: kAudioDevicePropertyDeviceName)
    }

    /// Read a Core Audio string property (name, UID, …) into a Swift String.
    private static func readStringProperty(
        _ id: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 1)
        defer { buffer.deallocate() }
        let getStatus = AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer)
        guard getStatus == noErr else { return nil }
        return String(cString: buffer.assumingMemoryBound(to: CChar.self))
    }
}
