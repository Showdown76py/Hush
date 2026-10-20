// Prototype étape 2 : micro + voice processing (VPIO) -> ring buffer -> sortie temps réel sur un
// périphérique (BlackHole). Option d'injection pour mesurer la latence (étape 3) :
// --inject <fichier> joue le fichier sur le canal 0 du périphérique de sortie, et le résultat VP
// est écrit sur le canal --out-channel (par défaut 0 sans injection, 2 avec).
// Usage : vp2out [--input <dev>] [--output <dev>] [--seconds N] [--inject file] [--buffer frames]
//                [--target frames] [--bypass]
import AudioToolbox
import AVFoundation
import CoreAudio
import CRing
import Foundation

var inputName: String?
var outputName = "BlackHole 16ch"
var seconds = 15.0
var injectPath: String?
var outChannel: Int?
var bufferFrames: UInt32 = 256
var targetFill: UInt32 = 768
var bypass = false
var injectChannels = 1
var useShm = false
var ioBuffer: UInt32? = nil
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--input": inputName = it.next()!
    case "--output": outputName = it.next()!
    case "--seconds": seconds = Double(it.next()!)!
    case "--inject": injectPath = it.next()!
    case "--out-channel": outChannel = Int(it.next()!)!
    case "--buffer": bufferFrames = UInt32(it.next()!)!
    case "--target": targetFill = UInt32(it.next()!)!
    case "--bypass": bypass = true
    case "--inject-channels": injectChannels = Int(it.next()!)!
    case "--shm": useShm = true
    case "--io-buffer": ioBuffer = UInt32(it.next()!)!
    default: fatalError("argument inconnu: \(a)")
    }
}
let vpChannel = outChannel ?? (injectPath == nil ? 0 : 2)
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
let sampleRate = 48000.0
func pcm(_ ch: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
}
let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)

// Fichier d'injection chargé en mémoire (mono 48 kHz)
var inject: [Float] = []
if let injectPath {
    let f = try AVAudioFile(forReading: URL(fileURLWithPath: injectPath))
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let conv = AVAudioConverter(from: f.processingFormat, to: fmt)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: inBuf)
    let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(f.length) * sampleRate / f.processingFormat.sampleRate) + 1024)!
    var done = false
    conv.convert(to: outBuf, error: nil) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true; status.pointee = .haveData; return inBuf
    }
    inject = Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    print("injection: \(inject.count) frames")
}

// Ring mono VP -> sortie
let ringCap: UInt32 = 8192
let ring = UnsafeMutableRawPointer.allocate(byteCount: ring_bytes(ringCap, 1), alignment: 64).assumingMemoryBound(to: ring_t.self)
ring_init(ring, ringCap, 1)

// Mémoire partagée avec le driver Hush (créée par le driver, ou par nous si absente).
var shm: UnsafeMutableRawPointer?
if useShm {
    var err: Int32 = 0
    guard let p = hush_app_map(&err) else { fatalError("mémoire partagée indisponible: errno \(err)") }
    shm = p
    hush_app_set_latency(p, targetFill, targetFill * 4)
}

final class Ctx {
    var vp: AudioUnit?
    let micBuf = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    let outBuf = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    var primed = false
    var underruns = 0, reprimes = 0, peakIn: Float = 0, peakOut: Float = 0
    var injectPos = 0
    var lastChunk: UInt32 = 0
    var prevFrames: UInt32 = 0
    var firstHost: UInt64 = 0, lastHost: UInt64 = 0, framesSinceFirst: UInt64 = 0
    var injectData: UnsafeMutablePointer<Float>?
    var injectCount = 0
}
let ctx = Ctx()
if !inject.isEmpty {
    ctx.injectData = .allocate(capacity: inject.count)
    ctx.injectData!.update(from: inject, count: inject.count)
    ctx.injectCount = inject.count
}
let ref = Unmanaged.passUnretained(ctx).toOpaque()

// Taille de buffer IO (pour notre processus) du micro et des haut-parleurs par défaut.
if var frames = ioBuffer {
    for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0); var sz = UInt32(4)
        AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &dev)
        var b = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        print("io buffer \(frames) sur \(dev) -> \(AudioObjectSetPropertyData(dev, &b, 0, nil, 4, &frames))")
    }
}

// --- VPIO (entrée micro) ---
var d1 = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                   componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
var u1: AudioUnit?
check(AudioComponentInstanceNew(AudioComponentFindNext(nil, &d1)!, &u1), "VPIO new")
let vp = u1!; ctx.vp = vp
var one: UInt32 = 1, zero: UInt32 = 0
check(AudioUnitSetProperty(vp, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "EnableIO in")
if let inputName {
    guard var dev = deviceID(named: inputName) else { fatalError("périphérique introuvable: \(inputName)") }
    check(AudioUnitSetProperty(vp, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &dev, 4), "input device")
}
var duck = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
check(AudioUnitSetProperty(vp, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &duck,
                           UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)), "ducking")
if bypass { check(AudioUnitSetProperty(vp, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &one, 4), "bypass") }
var mono = pcm(1)
check(AudioUnitSetProperty(vp, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &mono, asbdSize), "mic fmt")
check(AudioUnitSetProperty(vp, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &mono, asbdSize), "vp out fmt")
let micCB: AURenderCallback = { r, flags, ts, bus, frames, _ in
    let c = Unmanaged<Ctx>.fromOpaque(r).takeUnretainedValue()
    var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: c.micBuf))
    let err = AudioUnitRender(c.vp!, flags, ts, bus, frames, &abl)
    if err != noErr { return err }
    for i in 0..<Int(frames) { c.peakIn = max(c.peakIn, abs(c.micBuf[i])) }
    c.lastChunk = frames
    // frames produites avant ce callback / temps hôte écoulé depuis le premier callback
    if c.firstHost == 0 { c.firstHost = ts.pointee.mHostTime } else { c.framesSinceFirst += UInt64(c.prevFrames) }
    c.prevFrames = frames
    c.lastHost = ts.pointee.mHostTime
    if let shm {
        hush_app_write(shm, c.micBuf, frames, mach_absolute_time())
    } else {
        ring_write(ring, c.micBuf, frames)
    }
    return noErr
}
let silenceCB: AURenderCallback = { _, flags, _, _, _, io in
    for b in UnsafeMutableAudioBufferListPointer(io!) { memset(b.mData, 0, Int(b.mDataByteSize)) }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}
var s1 = AURenderCallbackStruct(inputProc: micCB, inputProcRefCon: ref)
var s2 = AURenderCallbackStruct(inputProc: silenceCB, inputProcRefCon: nil)
check(AudioUnitSetProperty(vp, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &s1, cbSize), "mic cb")
check(AudioUnitSetProperty(vp, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &s2, cbSize), "vp silence cb")
check(AudioUnitInitialize(vp), "VPIO init")

// --- AUHAL sortie sur le périphérique virtuel (pas en mode --shm) ---
if useShm {
    check(AudioOutputUnitStart(vp), "VPIO start")
    let t0 = Date()
    while seconds <= 0 || Date().timeIntervalSince(t0) < seconds {
        Thread.sleep(forTimeInterval: 1)
        let r = hush_app_reader_stats(shm!)
        var tbi = mach_timebase_info_data_t(); mach_timebase_info(&tbi)
        let secs = Double(ctx.lastHost - ctx.firstHost) * Double(tbi.numer) / Double(tbi.denom) / 1e9
        if secs > 0 { print(String(format: "rate=%.3f Hz (%.1f ppm)", Double(ctx.framesSinceFirst) / secs, (Double(ctx.framesSinceFirst) / secs / 48000 - 1) * 1e6)) }
        print(String(format: "t=%4.1f in=%6.1f dB chunk=%u driverFill=%4u underruns=%llu clients=%u", Date().timeIntervalSince(t0),
                     20 * log10(max(ctx.peakIn, 1e-9)), ctx.lastChunk, r.lastFill, r.underruns, r.clientsRunning))
        ctx.peakIn = 0
    }
    hush_app_stop(shm!)
    AudioOutputUnitStop(vp)
    print("ok")
    exit(0)
}
guard var outDev = deviceID(named: outputName) else { fatalError("périphérique introuvable: \(outputName)") }
var d2 = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                   componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
var u2: AudioUnit?
check(AudioComponentInstanceNew(AudioComponentFindNext(nil, &d2)!, &u2), "HAL new")
let hal = u2!
check(AudioUnitSetProperty(hal, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outDev, 4), "out device")
var bf = bufferFrames
var bfAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
print("buffer \(bufferFrames) -> status \(AudioObjectSetPropertyData(outDev, &bfAddr, 0, nil, 4, &bf))")
let outChans = UInt32(vpChannel + 2)
var outFmt = pcm(outChans)
check(AudioUnitSetProperty(hal, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFmt, asbdSize), "hal fmt")
let outCB: AURenderCallback = { r, _, _, _, frames, io in
    let c = Unmanaged<Ctx>.fromOpaque(r).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(io!)
    for b in abl { memset(b.mData, 0, Int(b.mDataByteSize)) }
    let n = Int(frames)
    // Injection éventuelle sur le canal 0
    if let inj = c.injectData {
        for ch in 0..<injectChannels {
            let dst = abl[ch].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<n where c.injectPos + i < c.injectCount { dst[i] = inj[c.injectPos + i] }
        }
        c.injectPos += n
    }
    // Sortie VP : on attend un remplissage cible avant de jouer (amorçage), et on ré-amorce sur underrun.
    if !c.primed {
        if ring_fill(ring) >= UInt64(targetFill) { c.primed = true } else { return noErr }
    }
    let got = ring_read(ring, c.outBuf, frames, targetFill, targetFill * 4)
    if got < frames { c.underruns += 1; c.primed = false }
    let vpL = abl[vpChannel].mData!.assumingMemoryBound(to: Float.self)
    let vpR = abl[vpChannel + 1].mData!.assumingMemoryBound(to: Float.self)
    for i in 0..<n { vpL[i] = c.outBuf[i]; vpR[i] = c.outBuf[i]; c.peakOut = max(c.peakOut, abs(c.outBuf[i])) }
    return noErr
}
var s3 = AURenderCallbackStruct(inputProc: outCB, inputProcRefCon: ref)
check(AudioUnitSetProperty(hal, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &s3, cbSize), "hal cb")
check(AudioUnitInitialize(hal), "HAL init")

check(AudioOutputUnitStart(vp), "VPIO start")
check(AudioOutputUnitStart(hal), "HAL start")
let t0 = Date()
while seconds <= 0 || Date().timeIntervalSince(t0) < seconds {
    Thread.sleep(forTimeInterval: 1)
    print(String(format: "t=%4.1f in=%6.1f dB out=%6.1f dB fill=%4d underruns=%d", Date().timeIntervalSince(t0),
                 20 * log10(max(ctx.peakIn, 1e-9)), 20 * log10(max(ctx.peakOut, 1e-9)), ring_fill(ring), ctx.underruns))
    ctx.peakIn = 0; ctx.peakOut = 0
}
AudioOutputUnitStop(hal); AudioOutputUnitStop(vp)
AudioUnitUninitialize(hal); AudioUnitUninitialize(vp)
print("ok")
