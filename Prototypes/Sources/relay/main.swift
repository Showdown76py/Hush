// Prototype architecture "relecture" :
//   1. tap Core Audio global (sauf nous-mêmes) qui COUPE la sortie d'origine des autres apps,
//   2. le son capturé est rejoué via la sortie du VPIO (canal "interlocuteur", jamais ducké,
//      et référence d'écho parfaite),
//   3. le micro traité par le VPIO est enregistré.
// Usage : relay --dir <outdir> [--seconds 14] [--input <device name>] [--target <frames>]
import AudioToolbox
import AVFoundation
import CoreAudio
import CRing
import Foundation

var outDir = "."
var seconds = 14.0
var inputName: String?
var targetFill: UInt32 = 960
var tapOnly = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--dir": outDir = it.next()!
    case "--seconds": seconds = Double(it.next()!)!
    case "--input": inputName = it.next()!
    case "--target": targetFill = UInt32(it.next()!)!
    case "--tap-only": tapOnly = true
    default: fatalError("argument inconnu: \(a)")
    }
}
func check(_ s: OSStatus, _ what: String) { if s != noErr { fatalError("\(what) a échoué: \(s)") } }
let sys = AudioObjectID(kAudioObjectSystemObject)
func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func deviceID(named name: String) -> AudioDeviceID? {
    var a = addr(kAudioHardwarePropertyDevices)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz)
    var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids)
    for id in ids {
        var na = addr(kAudioObjectPropertyName)
        var cf: Unmanaged<CFString>?
        var nsz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &na, 0, nil, &nsz, &cf) == noErr,
           let s = cf?.takeRetainedValue() as String?, s == name { return id }
    }
    return nil
}

let sampleRate = 48000.0
let channels: UInt32 = 2

// --- Enregistreurs pré-alloués (mesure uniquement) ---
final class Recorder {
    let cap: Int; let p: UnsafeMutablePointer<Float>; var n = 0
    init(seconds: Double) { cap = Int(sampleRate * (seconds + 1)); p = .allocate(capacity: cap); p.initialize(repeating: 0, count: cap) }
    @inline(__always) func push(_ v: Float) { if n < cap { p[n] = v; n += 1 } }
    func save(_ path: String) throws {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: f.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(max(n, 1)))!
        b.frameLength = AVAudioFrameCount(n); b.floatChannelData![0].update(from: p, count: n)
        try file.write(from: b)
    }
}
let recTapped = Recorder(seconds: seconds), recPlayed = Recorder(seconds: seconds), recMic = Recorder(seconds: seconds)

// --- Ring buffer tap -> sortie VPIO ---
let ringCapacity: UInt32 = 16384
let ringMem = UnsafeMutableRawPointer.allocate(byteCount: ring_bytes(ringCapacity, channels), alignment: 64)
let ring = ringMem.assumingMemoryBound(to: ring_t.self)
ring_init(ring, ringCapacity, channels)

final class Stats { var underruns = 0; var tapCallbacks = 0; var outCallbacks = 0; var tapFrames = 0; var outFrames = 0 }
let stats = Stats()

// --- 1. Tap système, en excluant notre propre processus ---
var pid = getpid()
var selfObj = AudioObjectID(kAudioObjectUnknown)
var a1 = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
var objSize = UInt32(MemoryLayout<AudioObjectID>.size)
check(AudioObjectGetPropertyData(sys, &a1, UInt32(MemoryLayout<pid_t>.size), &pid, &objSize, &selfObj), "TranslatePID")

let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObj])
tap.uuid = UUID()
tap.muteBehavior = .muted
tap.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tap, &tapID), "CreateProcessTap")
var tapFmt = AudioStreamBasicDescription()
var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var a2 = addr(kAudioTapPropertyFormat)
check(AudioObjectGetPropertyData(tapID, &a2, 0, nil, &fsz, &tapFmt), "tap format")
print("tap: \(tapFmt.mSampleRate) Hz \(tapFmt.mChannelsPerFrame) ch")
precondition(tapFmt.mSampleRate == sampleRate && tapFmt.mChannelsPerFrame == 2, "format de tap inattendu")

let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "relay-tap",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID), "CreateAggregateDevice")
var tapProc: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&tapProc, aggID, nil) { _, inData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    guard let b = abl.first, let p = b.mData?.assumingMemoryBound(to: Float.self), b.mNumberChannels == 2 else { return }
    let frames = UInt32(b.mDataByteSize) / 8
    ring_write(ring, p, frames)
    for i in 0..<Int(frames) { recTapped.push(0.5 * (p[2 * i] + p[2 * i + 1])) }
    stats.tapCallbacks += 1; stats.tapFrames += Int(frames)
}, "tap IOProc")

// --- 2. VPIO : micro traité + sortie = son rejoué ---
var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                     componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
var maybeUnit: AudioUnit?
check(AudioComponentInstanceNew(AudioComponentFindNext(nil, &desc)!, &maybeUnit), "VPIO new")
let unit = maybeUnit!
var one: UInt32 = 1
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "EnableIO in")
if let inputName {
    guard var dev = deviceID(named: inputName) else { fatalError("périphérique introuvable: \(inputName)") }
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &dev, 4), "input device")
}
var duck = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
check(AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &duck,
                           UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)), "ducking")

func pcm(_ ch: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
}
var micFmt = pcm(1), outFmt = pcm(channels)
let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &micFmt, asbdSize), "mic fmt")
let st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFmt, asbdSize)
print("VPIO sortie stéréo: status \(st)")
check(st, "out fmt stéréo")

final class IO { var unit: AudioUnit?; let mic = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
                 let inter = UnsafeMutablePointer<Float>.allocate(capacity: 16384) }
let io = IO(); io.unit = unit
let refCon = Unmanaged.passUnretained(io).toOpaque()

let micCB: AURenderCallback = { ref, flags, ts, bus, frames, _ in
    let io = Unmanaged<IO>.fromOpaque(ref).takeUnretainedValue()
    var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: io.mic))
    let err = AudioUnitRender(io.unit!, flags, ts, bus, frames, &abl)
    if err != noErr { return err }
    for i in 0..<Int(frames) { recMic.push(io.mic[i]) }
    return noErr
}
let outCB: AURenderCallback = { ref, _, _, _, frames, ioData in
    let io = Unmanaged<IO>.fromOpaque(ref).takeUnretainedValue()
    let got = ring_read(ring, io.inter, frames, targetFill, targetFill * 3)
    if got < frames { stats.underruns += 1 }
    let abl = UnsafeMutableAudioBufferListPointer(ioData!)
    let l = abl[0].mData!.assumingMemoryBound(to: Float.self), r = abl[1].mData!.assumingMemoryBound(to: Float.self)
    for i in 0..<Int(frames) {
        l[i] = io.inter[2 * i]; r[i] = io.inter[2 * i + 1]
        recPlayed.push(0.5 * (l[i] + r[i]))
    }
    stats.outCallbacks += 1; stats.outFrames += Int(frames)
    return noErr
}
var micStruct = AURenderCallbackStruct(inputProc: micCB, inputProcRefCon: refCon)
var outStruct = AURenderCallbackStruct(inputProc: outCB, inputProcRefCon: refCon)
let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &micStruct, cbSize), "mic cb")
check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outStruct, cbSize), "out cb")
check(AudioUnitInitialize(unit), "VPIO init")

check(AudioDeviceStart(aggID, tapProc), "tap start")
if !tapOnly { check(AudioOutputUnitStart(unit), "VPIO start") }
let t0 = Date()
while Date().timeIntervalSince(t0) < seconds {
    Thread.sleep(forTimeInterval: 1)
    print(String(format: "t=%4.1f fill=%5d underruns=%d tapCB=%d (%d fr) outCB=%d (%d fr)", Date().timeIntervalSince(t0),
                 ring_fill(ring), stats.underruns, stats.tapCallbacks, stats.tapFrames, stats.outCallbacks, stats.outFrames))
}
AudioOutputUnitStop(unit)
AudioDeviceStop(aggID, tapProc)
AudioUnitUninitialize(unit)
AudioDeviceDestroyIOProcID(aggID, tapProc!)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
try recTapped.save("\(outDir)/tapped.wav")
try recPlayed.save("\(outDir)/played.wav")
try recMic.save("\(outDir)/mic.wav")
print("ok")
