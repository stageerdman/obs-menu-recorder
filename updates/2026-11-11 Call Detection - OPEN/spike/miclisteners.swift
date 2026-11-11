// Throwaway spike: list every process CoreAudio reports as capturing audio input.
// Run: swift miclisteners.swift
import CoreAudio
import Foundation

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
    return status == noErr ? value : nil
}

var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
print("process objects: \(ids.count)")
for id in ids {
    let pid = prop(id, kAudioProcessPropertyPID, pid_t(0)) ?? -1
    let input = prop(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0
    let bundle = prop(id, kAudioProcessPropertyBundleID, CFString?.none).flatMap { $0 as String? } ?? "?"
    let output = prop(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0
    if CommandLine.arguments.contains("--all") || input != 0 { print("in=\(input) out=\(output) pid=\(pid) bundle=\(bundle)") }
}
