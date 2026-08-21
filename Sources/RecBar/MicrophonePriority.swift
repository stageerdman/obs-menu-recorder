import Foundation
import CoreAudio

struct AudioInputDevice {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
}

struct ResolvedMic {
    let role: MicSourceRole
    let deviceUID: String
    let deviceName: String
}

enum MicrophonePriorityError: Error, LocalizedError {
    case noEligibleDevice

    var errorDescription: String? {
        switch self {
        case .noEligibleDevice:
            return "No USB or built-in microphone found (Bluetooth and wired mics are never auto-selected)."
        }
    }
}

/// CoreAudio device enumeration + priority resolution.
///
/// Priority: USB mic > built-in mic. Bluetooth and wired (headphone-jack) mics are
/// never auto-selected, even if they're the only device besides "nothing" — this
/// mirrors OBS's built-in "BuiltInHeadphoneInputDevice" UID being excluded on purpose.
enum MicrophonePriority {
    /// Re-run on every recording start — USB mics may be plugged/unplugged between recordings.
    static func resolve() throws -> ResolvedMic {
        let devices = inputDevices()

        if let usb = devices.first(where: { $0.transportType == kAudioDeviceTransportTypeUSB }) {
            return ResolvedMic(role: .usb, deviceUID: usb.uid, deviceName: usb.name)
        }

        if let builtIn = devices.first(where: { $0.uid == "BuiltInMicrophoneDevice" }) {
            return ResolvedMic(role: .builtIn, deviceUID: builtIn.uid, deviceName: builtIn.name)
        }

        throw MicrophonePriorityError.noEligibleDevice
    }

    /// All devices with at least one input channel, annotated with transport type and UID.
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard inputChannelCount(deviceID) > 0 else { return nil }
            guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? uid
            let transport = transportType(deviceID)
            return AudioInputDevice(deviceID: deviceID, uid: uid, name: name, transportType: transport)
        }
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }
        return deviceIDs
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : 0
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else { return nil }
        return cfString as String
    }
}
