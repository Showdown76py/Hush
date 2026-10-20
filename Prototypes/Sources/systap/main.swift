// Enregistre la sortie audio système (tap Core Audio global) dans un WAV mono.
// Sert à mesurer objectivement le ducking : on mesure ce qui part vers les haut-parleurs.
// Usage : systap --out file.wav [--seconds 20]
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

var outPath = "systap.wav"
var seconds = 20.0
var tapPID: pid_t?
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--out": outPath = it.next()!
    case "--seconds": seconds = Double(it.next()!)!
    case "--pid": tapPID = pid_t(it.next()!)!
    default: fatalError("argument inconnu: \(a)")
    }
}
func check(_ s: OSStatus, _ what: String) { if s != noErr { fatalError("\(what) a échoué: \(s)") } }

var tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
if var pid = tapPID {
    var obj = AudioObjectID(kAudioObjectUnknown)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var osz = UInt32(MemoryLayout<AudioObjectID>.size)
    check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &osz, &obj), "TranslatePID")
    tap = CATapDescription(stereoMixdownOfProcesses: [obj])
}
tap.uuid = UUID()
tap.muteBehavior = .unmuted
tap.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tap, &tapID), "CreateProcessTap")

var fmt = AudioStreamBasicDescription()
var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                      mElement: kAudioObjectPropertyElementMain)
check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &sz, &fmt), "tap format")
print("tap format: \(fmt.mSampleRate) Hz, \(fmt.mChannelsPerFrame) ch, flags \(fmt.mFormatFlags)")

let agg: [String: Any] = [
    kAudioAggregateDeviceNameKey: "systap",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "CreateAggregateDevice")

let sr = fmt.mSampleRate
let capacity = Int(sr * (seconds + 1))
let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
samples.initialize(repeating: 0, count: capacity)
nonisolated(unsafe) var written = 0
let chans = Int(fmt.mChannelsPerFrame)

var procID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    guard let b = abl.first, let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
    let ch = Int(b.mNumberChannels)
    let frames = Int(b.mDataByteSize) / 4 / max(ch, 1)
    let n = min(frames, capacity - written)
    for i in 0..<n {
        var s: Float = 0
        for c in 0..<ch { s += p[i * ch + c] }
        samples[written + i] = s / Float(ch)
    }
    written += n
}, "CreateIOProc")
_ = chans
check(AudioDeviceStart(aggID, procID), "DeviceStart")
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(aggID, procID)
AudioDeviceDestroyIOProcID(aggID, procID!)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)

let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
let file = try AVAudioFile(forWriting: URL(fileURLWithPath: outPath), settings: mono.settings,
                           commonFormat: .pcmFormatFloat32, interleaved: false)
let buf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(max(written, 1)))!
buf.frameLength = AVAudioFrameCount(written)
buf.floatChannelData![0].update(from: samples, count: written)
try file.write(from: buf)
print("écrit: \(outPath) (\(written) frames)")
