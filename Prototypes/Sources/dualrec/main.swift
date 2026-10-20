// Enregistre deux périphériques d'entrée en parallèle (canal 0 de chacun) et les aligne grâce aux
// horodatages hôte (mHostTime) du premier buffer de chaque flux. Produit un WAV stéréo :
// gauche = périphérique A, droite = périphérique B, alignés dans le temps réel.
// Affiche aussi les latences déclarées par les périphériques.
// Usage : dualrec --a <dev> --b <dev> --out file.wav [--seconds 15]
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

var nameA = "MacBook Air Microphone", nameB = "BlackHole 16ch", outPath = "dual.wav", seconds = 15.0
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--a": nameA = it.next()!
    case "--b": nameB = it.next()!
    case "--out": outPath = it.next()!
    case "--seconds": seconds = Double(it.next()!)!
    default: fatalError("argument inconnu: \(a)")
    }
}
func check(_ s: OSStatus, _ what: String) { if s != noErr { fatalError("\(what) a échoué: \(s)") } }
let sys = AudioObjectID(kAudioObjectSystemObject)
func deviceID(named name: String) -> AudioDeviceID? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz)
    var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids)
    for id in ids {
        var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var nsz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &na, 0, nil, &nsz, &cf) == noErr,
           let s = cf?.takeRetainedValue() as String?, s == name { return id }
    }
    return nil
}
func u32(_ dev: AudioDeviceID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0, sz: UInt32 = 4
    AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v)
    return v
}
func streamLatency(_ dev: AudioDeviceID) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                       mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &sz)
    var ids = [AudioStreamID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &ids)
    guard let s = ids.first else { return 0 }
    return u32(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
}

let sr = 48000.0
final class Rec {
    let cap: Int; let p: UnsafeMutablePointer<Float>; var n = 0; var firstHost: UInt64 = 0
    var unit: AudioUnit?; let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    init() { cap = Int(sr * (seconds + 2)); p = .allocate(capacity: cap); p.initialize(repeating: 0, count: cap) }
}
func makeInput(_ name: String, _ rec: Rec) -> AudioUnit {
    guard var dev = deviceID(named: name) else { fatalError("périphérique introuvable: \(name)") }
    let s = kAudioObjectPropertyScopeInput
    print("\(name): latency=\(u32(dev, kAudioDevicePropertyLatency, s)) safety=\(u32(dev, kAudioDevicePropertySafetyOffset, s)) " +
          "stream=\(streamLatency(dev)) buffer=\(u32(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)) frames")
    var d = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    var u: AudioUnit?
    check(AudioComponentInstanceNew(AudioComponentFindNext(nil, &d)!, &u), "new")
    let unit = u!
    var one: UInt32 = 1, zero: UInt32 = 0
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "in")
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "out")
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4), "dev")
    // Canal 0 uniquement, en mono 48 kHz.
    var fmt = AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt,
                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "fmt")
    var map: [Int32] = [0]
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &map, 4), "map")
    rec.unit = unit
    let cb: AURenderCallback = { r, flags, ts, bus, frames, _ in
        let rec = Unmanaged<Rec>.fromOpaque(r).takeUnretainedValue()
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: rec.scratch))
        let err = AudioUnitRender(rec.unit!, flags, ts, bus, frames, &abl)
        if err != noErr { return err }
        if rec.firstHost == 0 { rec.firstHost = ts.pointee.mHostTime }
        let n = min(Int(frames), rec.cap - rec.n)
        rec.p.advanced(by: rec.n).update(from: rec.scratch, count: n)
        rec.n += n
        return noErr
    }
    var s1 = AURenderCallbackStruct(inputProc: cb, inputProcRefCon: Unmanaged.passUnretained(rec).toOpaque())
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &s1,
                               UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "cb")
    check(AudioUnitInitialize(unit), "init")
    return unit
}
let ra = Rec(), rb = Rec()
let ua = makeInput(nameA, ra), ub = makeInput(nameB, rb)
check(AudioOutputUnitStart(ua), "start a"); check(AudioOutputUnitStart(ub), "start b")
Thread.sleep(forTimeInterval: seconds)
AudioOutputUnitStop(ua); AudioOutputUnitStop(ub)

var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
let dtSec = (Double(Int64(rb.firstHost) - Int64(ra.firstHost)) * Double(tb.numer) / Double(tb.denom)) / 1e9
let shift = Int((dtSec * sr).rounded())   // B commence `shift` frames après A
let firstANs = Double(ra.firstHost) * Double(tb.numer) / Double(tb.denom) + Double(max(0, shift)) / sr * 1e9
try String(firstANs).write(toFile: outPath + ".t0", atomically: true, encoding: .utf8)
print(String(format: "décalage de départ B-A = %.2f ms (%d frames)", dtSec * 1000, shift))
let n = min(ra.n, rb.n + shift) - max(0, shift)
let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
buf.frameLength = AVAudioFrameCount(n)
let L = buf.floatChannelData![0], R = buf.floatChannelData![1]
for i in 0..<n {
    let ia = i + max(0, shift), ib = i + max(0, shift) - shift
    L[i] = ra.p[ia]; R[i] = (ib >= 0 && ib < rb.n) ? rb.p[ib] : 0
}
let file = try AVAudioFile(forWriting: URL(fileURLWithPath: outPath), settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
try file.write(from: buf)
print("écrit: \(outPath) (\(n) frames)")
