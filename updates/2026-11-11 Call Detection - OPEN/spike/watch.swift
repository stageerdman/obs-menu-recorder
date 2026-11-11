// Throwaway spike: log, twice a second, every process with input running + whether any input device is running.
import CoreAudio
import Foundation

func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = v; var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) } == noErr ? value : nil
}
func list(_ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}
func name(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let s = v?.takeRetainedValue() else { return "?" }
    return s as String
}
let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"
var last = ""
while true {
    var parts: [String] = []
    for p in list(kAudioHardwarePropertyProcessObjectList) {
        let inp = get(p, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0
        if inp != 0 { parts.append("proc:\(name(p, kAudioProcessPropertyBundleID))/pid\(get(p, kAudioProcessPropertyPID, pid_t(0)) ?? -1)") }
    }
    for d in list(kAudioHardwarePropertyDevices) {
        let running = get(d, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) ?? 0
        if running != 0 { parts.append("dev:\(name(d, kAudioObjectPropertyName))") }
    }
    let line = parts.sorted().joined(separator: " ")
    if line != last { print("\(f.string(from: Date())) \(line.isEmpty ? "(nothing)" : line)"); fflush(stdout); last = line }
    usleep(500_000)
}
