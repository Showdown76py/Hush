// Fait tourner le moteur réel de l'app (VoiceEngine + hush_rt.c) hors de l'app, vers le driver Hush.
// Usage : enginecheck [secondes]
import Foundation
import HushRT

let switchTest = CommandLine.arguments.contains("--switch")
if CommandLine.arguments.contains("--duck-release") {
    // Voice processing 10 s puis arrêt, le processus reste vivant 30 s (comme l'app).
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
    // 0-10 s : passage direct ; 10-20 s : voice processing ; 20-30 s : passage direct.
    try engine.startRawMonitor(device: source.id)
    engine.setPassthrough(shm.pointer)
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        engine.setPassthrough(nil)
        try! engine.start(.init(inputDevice: source.id, keepAppleDucking: false), shm: shm.pointer)
        print("→ voice processing")
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
        engine.stop()
        if CommandLine.arguments.contains("--reopen") {
            engine.stopRawMonitor()
            try! engine.startRawMonitor(device: source.id)
        }
        engine.setPassthrough(shm.pointer)
        print("→ passage direct")
    }
} else {
    try engine.start(.init(inputDevice: source.id, keepAppleDucking: false), shm: shm.pointer)
    try engine.startRawMonitor(device: source.id)
}
hush_rt_record_start(engine.rt, 0, 48000)
let t0 = Date()
var lastCallbacks: UInt64 = 0
while Date().timeIntervalSince(t0) < seconds {
    Thread.sleep(forTimeInterval: 5)
    let s = shm.stats
    let cb = engine.callbackCount
    print(String(format: "t=%3.0fs callbacks/s=%4.0f erreurs=%llu propre=%5.1f dB brut=%5.1f dB clients=%d fill=%4u underruns=%llu glissements=%lld enregistrement=%@",
                 Date().timeIntervalSince(t0), Double(cb - lastCallbacks) / 5, engine.errorCount,
                 20 * log10(max(engine.cleanLevel, 1e-6)), 20 * log10(max(engine.rawLevel, 1e-6)),
                 s.clients, s.fill, s.underruns, engine.driftSlips, hush_rt_record_done(engine.rt) != 0 ? "ok" : "en cours"))
    lastCallbacks = cb
}
engine.stopRawMonitor()
engine.stop()
print("arrêt propre ; le driver repasse au silence")
