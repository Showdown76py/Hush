// step 1 prototype: mic capture w/ or w/o vp to a wav
// uses the VoiceProcessingIO audio unit directly (AVAudioEngine fails w/ -10875
// initializing the output node on macOS 27)
// usage: vpcapture --out file.wav [--seconds 15] [--raw] [--duck]
//   --raw   raw HAL (AUHAL) instead of vp
//   --duck  keep apple's default ducking (otherwise ducking off)
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

var outPath = "out.wav"
var seconds = 15.0
var useVP = true
var keepDucking = false
var inputName: String?
var advanced = false
var level: UInt32? = nil
var rawProps: [(UInt32, UInt32)] = []
var disableOutput = false
var outputName: String?

func deviceID(named name: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz)
    var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &ids)
    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var nsz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsz, &cf) == noErr,
           let s = cf?.takeRetainedValue() as String?, s == name { return id }
    }
    return nil
}

var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--out": outPath = it.next()!
    case "--seconds": seconds = Double(it.next()!)!
    case "--raw": useVP = false
    case "--duck": keepDucking = true
    case "--input": inputName = it.next()!
    case "--advanced": advanced = true
    case "--level": level = UInt32(it.next()!)!
    case "--prop":
        let kv = it.next()!.split(separator: "=").map { UInt32($0)! }
        rawProps.append((kv[0], kv[1]))
    case "--no-output": disableOutput = true
    case "--output": outputName = it.next()!
    default: fatalError("argument inconnu: \(a)")
    }
}

func check(_ s: OSStatus, _ what: String) {
    if s != noErr { fatalError("\(what) a échoué: \(s)") }
}

let sampleRate = 48000.0
var desc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: useVP ? kAudioUnitSubType_VoiceProcessingIO : kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
var maybeUnit: AudioUnit?
check(AudioComponentInstanceNew(AudioComponentFindNext(nil, &desc)!, &maybeUnit), "AudioComponentInstanceNew")
let unit = maybeUnit!

var one: UInt32 = 1, zero: UInt32 = 0
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "EnableIO in")
if !useVP {
    // auhal input only on default input device
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "EnableIO out")
    var dev = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev), "default input")
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, sz), "CurrentDevice")
}

if useVP, let inputName {
    guard var dev = deviceID(named: inputName) else { fatalError("périphérique introuvable: \(inputName)") }
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &dev, 4),
          "CurrentDevice input")
    print("VP input device: \(inputName) (\(dev))")
}

if useVP, let outputName {
    guard var dev = deviceID(named: outputName) else { fatalError("périphérique introuvable: \(outputName)") }
    check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4),
          "CurrentDevice output")
    print("VP output device: \(outputName) (\(dev))")
}

if useVP {
    var duck = AUVoiceIOOtherAudioDuckingConfiguration(
        mEnableAdvancedDucking: advanced ? true : false,
        mDuckingLevel: AUVoiceIOOtherAudioDuckingLevel(rawValue: level ?? (keepDucking ? 0 : 10))!)
    check(AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
                               &duck, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)), "Ducking")
    for (id, v) in rawProps {
        var val = v
        let st = AudioUnitSetProperty(unit, id, kAudioUnitScope_Global, 0, &val, 4)
        print("prop \(id)=\(v) -> status \(st)")
    }
    if disableOutput {
        print("EnableIO out=0 -> \(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4))")
    }
    print("VP on, ducking level=\(duck.mDuckingLevel.rawValue) advanced=\(duck.mEnableAdvancedDucking)")
}

var fmt = AudioStreamBasicDescription(
    mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, fmtSize), "fmt in")
if useVP {
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, fmtSize), "fmt out")
}

// buffer preallocated for the whole run so no alloc in the callback
final class State {
    let capacity: Int
    let samples: UnsafeMutablePointer<Float>
    var written = 0
    var peak: Float = 0
    let scratch: UnsafeMutablePointer<Float>
    var unit: AudioUnit?
    init(capacity: Int) {
        self.capacity = capacity
        samples = .allocate(capacity: capacity); samples.initialize(repeating: 0, count: capacity)
        scratch = .allocate(capacity: 8192)
    }
}
let state = State(capacity: Int(sampleRate * (seconds + 1)))
state.unit = unit

let inputCallback: AURenderCallback = { refCon, flags, ts, bus, frames, _ in
    let st = Unmanaged<State>.fromOpaque(refCon).takeUnretainedValue()
    var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
        mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(st.scratch)))
    let err = AudioUnitRender(st.unit!, flags, ts, bus, frames, &abl)
    if err != noErr { return err }
    let n = min(Int(frames), st.capacity - st.written)
    for i in 0..<n {
        let v = st.scratch[i]
        st.samples[st.written + i] = v
        st.peak = max(st.peak, abs(v))
    }
    st.written += n
    return noErr
}
var cb = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: Unmanaged.passUnretained(state).toOpaque())
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetInputCallback")

if useVP && !disableOutput {
    // vpio output bus plays silence (we don't play anything)
    let silence: AURenderCallback = { _, flags, _, _, _, ioData in
        let abl = UnsafeMutableAudioBufferListPointer(ioData!)
        for b in abl { memset(b.mData, 0, Int(b.mDataByteSize)) }
        flags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return noErr
    }
    var out = AURenderCallbackStruct(inputProc: silence, inputProcRefCon: nil)
    check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &out,
                               UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetRenderCallback")
}

check(AudioUnitInitialize(unit), "AudioUnitInitialize")
check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
let start = Date()
while Date().timeIntervalSince(start) < seconds {
    Thread.sleep(forTimeInterval: 1)
    print(String(format: "t=%4.1fs peak=%6.1f dBFS frames=%d", Date().timeIntervalSince(start),
                 20 * log10(max(state.peak, 1e-9)), state.written))
    state.peak = 0
}
AudioOutputUnitStop(unit)
AudioUnitUninitialize(unit)

let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
let file = try AVAudioFile(forWriting: URL(fileURLWithPath: outPath), settings: monoFmt.settings,
                           commonFormat: .pcmFormatFloat32, interleaved: false)
let buf = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: AVAudioFrameCount(state.written))!
buf.frameLength = AVAudioFrameCount(state.written)
buf.floatChannelData![0].update(from: state.samples, count: state.written)
try file.write(from: buf)
print("écrit: \(outPath) (\(state.written) frames)")
