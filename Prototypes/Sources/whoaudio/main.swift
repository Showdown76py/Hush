// Liste les processus qui utilisent l'entrée ou la sortie audio en ce moment (macOS 14+).
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
var a = addr(kAudioHardwarePropertyProcessObjectList)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var objs = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &objs)
func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
    var ad = addr(s); var v: UInt32 = 0; var sz: UInt32 = 4
    AudioObjectGetPropertyData(o, &ad, 0, nil, &sz, &v); return v
}
for o in objs {
    let input = u32(o, kAudioProcessPropertyIsRunningInput), output = u32(o, kAudioProcessPropertyIsRunningOutput)
    guard input != 0 || output != 0 else { continue }
    var ad = addr(kAudioProcessPropertyPID); var pid: pid_t = 0; var sz = UInt32(MemoryLayout<pid_t>.size)
    AudioObjectGetPropertyData(o, &ad, 0, nil, &sz, &pid)
    var bad = addr(kAudioProcessPropertyBundleID); var cf: Unmanaged<CFString>?; var csz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(o, &bad, 0, nil, &csz, &cf)
    let bundle = (cf?.takeRetainedValue() as String?) ?? "?"
    print(String(format: "pid %6d  entrée=%@  sortie=%@  %@", pid, input != 0 ? "OUI" : "non", output != 0 ? "OUI" : "non", bundle))
}
