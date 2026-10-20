// runs the real app engine (VoiceEngine + hush_rt.c) outside the app into the hush driver
// usage: enginecheck [seconds]
import Foundation
import HushRT

let switchTest = CommandLine.arguments.contains("--switch")
if CommandLine.arguments.contains("--aggregates") {
    // list devices this process sees before/during/after vp
    func snapshot() -> String {
        AudioDevices.allDeviceIDs().map { id in
            "\(id):\(AudioDevices.string(id, kAudioObjectPropertyName) ?? "?")[\(AudioDevices.uint32(id, kAudioDevicePropertyTransportType).map { String(format: "%08x", $0) } ?? "?")]"
        }.joined(separator: " ")
    }
    print("avant : \(snapshot())")
    let shm = try SharedMemory()
    let engine = VoiceEngine()
    let source = AudioDevices.resolveSource(preferredUID: nil)!
    try engine.start(.init(inputDevice: source.id, keepAppleDucking: false), shm: shm.pointer)
    Thread.sleep(forTimeInterval: 3)
    print("pendant : \(snapshot())")
    engine.stop()
    var last = ""
    for t in 0..<40 {
        let s = snapshot()
        if s != last { print("t=+\(t)s après arrêt : \(s)"); last = s }
        Thread.sleep(forTimeInterval: 1)
    }
    exit(0)
}
if CommandLine.arguments.contains("--vp-hold") {
    // vp held 40 s to watch ducking at activation
    let shm = try SharedMemory()
    let engine = VoiceEngine()
    let source = AudioDevices.resolveSource(preferredUID: nil)!
    try engine.start(.init(inputDevice: source.id, keepAppleDucking: false), shm: shm.pointer)
    Thread.sleep(forTimeInterval: 40)
    engine.stop()
    exit(0)
}
if CommandLine.arguments.contains("--duck-release") {
    // vp 10 s then stop, process stays alive 30 s (like the app)
    let shm = try SharedMemory()
    let engine = VoiceEngine()
    let source = AudioDevices.resolveSource(preferredUID: nil)!
    try engine.start(.init(inputDevice: source.id, keepAppleDucking: false), shm: shm.pointer)
    print("VP démarré"); fflush(stdout)
    Thread.sleep(forTimeInterval: 10)
    engine.stop()
    print("VP arrêté à t=10 s"); fflush(stdout)
    Thread.sleep(forTimeInterval: 30)
    exit(0)
}
let seconds = switchTest ? 30 : (Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60)
let shm = try SharedMemory()
let engine = VoiceEngine()
guard let source = AudioDevices.resolveSource(preferredUID: nil) else { fatalError("pas de micro") }
print("source : \(source.name)")
if switchTest {
    // 0-10 s passthrough, 10-20 s vp, 20-30 s passthrough
    try engine.startRawMonitor(device: source.id)
    try engine.setPassthrough(shm.pointer)
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        try? engine.setPassthrough(nil)
        try! engine.start(.init(inputDevice: source.id, keepAppleDucking: false), shm: shm.pointer)
        print("→ voice processing")
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
        engine.stop()
        if CommandLine.arguments.contains("--reopen") {
            engine.stopRawMonitor()
            try! engine.startRawMonitor(device: source.id)
        }
        try? engine.setPassthrough(shm.pointer)
        print("→ passage direct")
    }
} else {
    try engine.start(.init(inputDevice: source.id, keepAppleDucking: false), shm: shm.pointer)
    try engine.startRawMonitor(device: source.id)
}
hush_rt_record_start(engine.rt, 0, 48000)
let interval: Double = CommandLine.arguments.contains("--fast") ? 1 : 5
let t0 = Date()
var lastCallbacks: UInt64 = 0
while Date().timeIntervalSince(t0) < seconds {
    Thread.sleep(forTimeInterval: interval)
    let s = shm.stats
    let cb = engine.callbackCount
    print(String(format: "gain auto=%5.1f dB dérive=%+6.2f ppm ", engine.automaticGainDB, engine.driftPPM), terminator: "")
    print(String(format: "t=%3.0fs callbacks/s=%4.0f erreurs=%llu propre=%5.1f dB brut=%5.1f dB clients=%d fill=%4u underruns=%llu glissements=%lld enregistrement=%@",
                 Date().timeIntervalSince(t0), Double(cb - lastCallbacks) / interval, engine.errorCount,
                 20 * log10(max(engine.cleanLevel, 1e-6)), 20 * log10(max(engine.rawLevel, 1e-6)),
                 s.clients, s.fill, s.underruns, engine.driftSlips, hush_rt_record_done(engine.rt) != 0 ? "ok" : "en cours"))
    lastCallbacks = cb
}
engine.stopRawMonitor()
engine.stop()
print("arrêt propre ; le driver repasse au silence")
