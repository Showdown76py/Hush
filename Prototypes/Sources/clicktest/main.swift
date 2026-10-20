// Joue des clics sur la sortie par défaut à intervalles réguliers et enregistre l'heure hôte
// (en ns) de chaque clic, telle que donnée par l'horodatage de sortie. Sert de référence absolue
// pour mesurer la latence d'un chemin d'entrée.
// Usage : clicktest --out times.txt [--seconds 10] [--first 2.0] [--interval 1.5]
import AudioToolbox
import CoreAudio
import Foundation

var outPath = "clicks.txt", seconds = 10.0, first = 2.0, interval = 1.5
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--out": outPath = it.next()!
    case "--seconds": seconds = Double(it.next()!)!
    case "--first": first = Double(it.next()!)!
    case "--interval": interval = Double(it.next()!)!
    default: fatalError("argument inconnu: \(a)")
    }
}
func check(_ s: OSStatus, _ what: String) { if s != noErr { fatalError("\(what) a échoué: \(s)") } }
let sr = 48000.0
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)

final class Ctx {
    var pos: Int64 = 0                 // frames jouées
    var nextClick: Int64 = 0
    var times = UnsafeMutablePointer<UInt64>.allocate(capacity: 1000)
    var count = 0
}
let ctx = Ctx()
ctx.nextClick = Int64(first * sr)
let clickLen = 96   // 2 ms, bruit large bande décroissant
var click = [Float](repeating: 0, count: clickLen)
var seed: UInt32 = 12345
for i in 0..<clickLen {
    seed = seed &* 1664525 &+ 1013904223
    let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
    click[i] = 0.8 * noise * expf(-Float(i) / 20)
}
let clickPtr = UnsafeMutablePointer<Float>.allocate(capacity: clickLen)
clickPtr.update(from: click, count: clickLen)
let intervalFrames = Int64(interval * sr)

var d = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
                                  componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
var u: AudioUnit?
check(AudioComponentInstanceNew(AudioComponentFindNext(nil, &d)!, &u), "new")
let unit = u!
var fmt = AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt,
                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "fmt")
let cb: AURenderCallback = { r, _, ts, _, frames, io in
    let c = Unmanaged<Ctx>.fromOpaque(r).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(io!)
    for b in abl { memset(b.mData, 0, Int(b.mDataByteSize)) }
    let n = Int64(frames)
    var k = c.nextClick
    while k < c.pos + n + Int64(clickLen) {
        for i in 0..<clickLen {
            let p = k + Int64(i) - c.pos
            if p >= 0 && p < n { for b in abl { b.mData!.assumingMemoryBound(to: Float.self)[Int(p)] = clickPtr[i] } }
        }
        if k >= c.pos && k < c.pos + n && c.count < 1000 {
            // heure hôte du premier échantillon du buffer + décalage du clic
            c.times[c.count] = ts.pointee.mHostTime + UInt64(Double(k - c.pos) / sr * 1e9 * Double(tb.denom) / Double(tb.numer))
            c.count += 1
        }
        if k + Int64(clickLen) <= c.pos + n { k += intervalFrames; c.nextClick = k } else { break }
    }
    c.pos += n
    return noErr
}
var s = AURenderCallbackStruct(inputProc: cb, inputProcRefCon: Unmanaged.passUnretained(ctx).toOpaque())
check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &s,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "cb")
check(AudioUnitInitialize(unit), "init")
check(AudioOutputUnitStart(unit), "start")
Thread.sleep(forTimeInterval: seconds)
AudioOutputUnitStop(unit)
let lines = (0..<ctx.count).map { String(Double(ctx.times[$0]) * Double(tb.numer) / Double(tb.denom)) }
try lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
print("\(ctx.count) clics")
