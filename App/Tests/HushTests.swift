import XCTest
@testable import Hush

final class SharedMemoryContractTests: XCTestCase {
    /// plain memory (never the installed driver's real shm)
    private func makeRegion() -> UnsafeMutableRawPointer {
        let p = UnsafeMutableRawPointer.allocate(byteCount: hush_shm_bytes(), alignment: 64)
        p.initializeMemory(as: UInt8.self, repeating: 0, count: hush_shm_bytes())
        return p
    }

    func testAttachInitialisesOnlyOnce() {
        let p = makeRegion(); defer { p.deallocate() }
        XCTAssertEqual(hush_app_attach(p, hush_shm_bytes()), 1, "première ouverture : en-tête initialisé")
        XCTAssertEqual(hush_app_attach(p, hush_shm_bytes()), 0, "ouverture suivante : en-tête conservé")
        XCTAssertEqual(hush_app_attach(p, hush_shm_bytes() - 1) , 1, "taille insuffisante : réinitialisé")
    }

    func testWriteUpdatesHeartbeatAndStopClearsIt() {
        let p = makeRegion(); defer { p.deallocate() }
        hush_app_attach(p, hush_shm_bytes())
        var samples = [Float](repeating: 0.25, count: 480)
        hush_app_write(p, &samples, 480, 1234)
        XCTAssertEqual(hush_app_reader_stats(p).clientsRunning, 0)
        hush_app_stop(p)
    }
}

final class SingleWriterTests: XCTestCase {
    private func region() -> UnsafeMutableRawPointer {
        let p = UnsafeMutableRawPointer.allocate(byteCount: hush_shm_bytes(), alignment: 64)
        p.initializeMemory(as: UInt8.self, repeating: 0, count: hush_shm_bytes())
        hush_app_attach(p, hush_shm_bytes())
        return p
    }

    func testOnlyOneLiveProcessCanWrite() {
        let p = region(); defer { p.deallocate() }
        let me = UInt32(getpid())
        XCTAssertEqual(hush_app_claim_writer(p, me), 1)
        XCTAssertEqual(hush_app_claim_writer(p, me), 1, "réentrant pour le même processus")
        XCTAssertEqual(hush_app_claim_writer(p, 1), 0, "refusé tant que le propriétaire vit")
        hush_app_release_writer(p, me)
        XCTAssertEqual(hush_app_claim_writer(p, 1), 1, "libre après libération")
    }

    func testDeadOwnerIsReplaced() {
        let p = region(); defer { p.deallocate() }
        XCTAssertEqual(hush_app_claim_writer(p, 999_999), 1)   // nonexistent pid
        XCTAssertEqual(hush_app_claim_writer(p, UInt32(getpid())), 1, "propriétaire mort remplacé")
    }
}

final class RealTimeTests: XCTestCase {
    func testRecordBufferStartsEmptyAndClamps() {
        let rt = hush_rt_create()!
        defer { hush_rt_destroy(rt) }
        XCTAssertEqual(hush_rt_record_done(rt), 0)
        hush_rt_record_start(rt, 0, UInt32.max)
        XCTAssertEqual(hush_rt_record_progress(rt), 0)
        XCTAssertEqual(hush_rt_record_done(rt), 0)
        XCTAssertEqual(hush_rt_level_clean(rt), 0)
        XCTAssertEqual(hush_rt_drift_slips(rt), 0)
    }

    func testSilenceOutputZeroesAndFlags() {
        var data = [Float](repeating: 1, count: 256)
        data.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 1024, mData: raw.baseAddress))
            var flags = AudioUnitRenderActionFlags()
            var ts = AudioTimeStamp()
            var dummy = 0
            XCTAssertEqual(hush_rt_silence_output(&dummy, &flags, &ts, 0, 256, &abl), noErr)
            XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))
        }
        XCTAssertTrue(data.allSatisfy { $0 == 0 })
    }
}

final class GainTests: XCTestCase {
    func testUnityGainIsIdentityBelowTheKnee() {
        var x: [Float] = [0, 0.1, -0.5, 0.89]
        let before = x
        hush_rt_apply_gain(&x, UInt32(x.count), 1)
        XCTAssertEqual(x, before)
    }

    func testGainIsLinearBelowTheKnee() {
        var x: [Float] = [0.01, -0.05]
        hush_rt_apply_gain(&x, 2, 4)   // +12 dB
        XCTAssertEqual(x[0], 0.04, accuracy: 1e-6)
        XCTAssertEqual(x[1], -0.2, accuracy: 1e-6)
    }

    func testLimiterNeverClips() {
        var x: [Float] = (0..<200).map { Float($0) / 100 - 1 }   // -1 … +1
        hush_rt_apply_gain(&x, UInt32(x.count), 8)              // +18 dB
        XCTAssertLessThanOrEqual(x.map(abs).max()!, 1.0)
        for i in 1..<x.count { XCTAssertGreaterThanOrEqual(x[i], x[i - 1], "monotone") }
    }
}

final class VoiceAGCTests: XCTestCase {
    private let sr: Float = 48000
    private let block = 256
    private var seed: UInt32 = 1

    private func noise() -> Float {
        seed = seed &* 1664525 &+ 1013904223
        return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 1.732   // RMS ~1
    }

    /// fake speech: noise modulated by syllables (4 Hz), 1.5 s phrases w/ 0.5 s pauses
    /// at RMS `speechDB` while talking over a noise floor at `floorDB`
    private func speech(seconds: Float, speechDB: Float, floorDB: Float = -75) -> [Float] {
        let n = Int(seconds * sr)
        let a = powf(10, speechDB / 20) * 1.63, f = powf(10, floorDB / 20)
        return (0..<n).map { i in
            let t = Float(i) / sr
            let inSentence = t.truncatingRemainder(dividingBy: 2) < 1.5
            let syllable = max(0, sinf(2 * .pi * 4 * t))
            return (inSentence ? a * syllable * syllable * noise() : 0) + f * noise()
        }
    }

    private func run(_ agc: inout hush_agc_t, _ x: [Float]) -> [Float] {
        var y = x
        y.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                let n = min(block, p.count - i)
                hush_agc_process(&agc, p.baseAddress! + i, UInt32(n))
                i += n
            }
        }
        return y
    }

    /// RMS level (dB) of output speech parts over the last `lastSeconds` seconds
    private func speechLevel(_ y: [Float], lastSeconds: Float) -> Float {
        let start = y.count - Int(lastSeconds * sr)
        var sum: Float = 0, count = 0
        for i in start..<y.count where (Float(i) / sr).truncatingRemainder(dividingBy: 2) < 1.5 {
            sum += y[i] * y[i]; count += 1
        }
        return 10 * log10f(sum / Float(count))
    }

    func testQuietVoiceIsRaisedToTarget() {
        var agc = hush_agc_t()
        hush_agc_init(&agc, sr, 0)
        let y = run(&agc, speech(seconds: 14, speechDB: -44))
        // target is per speech block. a synthetic phrase averages ~3 dB below
        XCTAssertEqual(speechLevel(y, lastSeconds: 4), agc.targetDB - 3, accuracy: 4, "voix faible ramenée vers la cible")
    }

    func testLoudVoiceIsLowered() {
        var agc = hush_agc_t()
        hush_agc_init(&agc, sr, 12)
        let y = run(&agc, speech(seconds: 6, speechDB: -14))
        XCTAssertLessThan(agc.gainDB, 0, "gain réduit pour une voix forte")
        XCTAssertLessThanOrEqual(y.map(abs).max()!, 1.0, "jamais de saturation")
    }

    func testMusicResidualIsNeverRaised() {
        // music residue left by vp: -58 dB bursts between -85 dB silences
        var agc = hush_agc_t()
        hush_agc_init(&agc, sr, 10)
        var x = [Float]()
        for k in 0..<40 {
            let level: Float = k % 2 == 0 ? -58 : -85
            let a = powf(10, level / 20)
            x += (0..<Int(0.5 * sr)).map { _ in a * noise() }
        }
        _ = run(&agc, x)
        XCTAssertEqual(agc.gainDB, 10, accuracy: 0.5, "le gain ne monte pas sur le résidu")
    }

    func testSteadyNoiseKeepsGainFrozen() {
        var agc = hush_agc_t()
        hush_agc_init(&agc, sr, 8)
        let a = powf(10, -60 / 20)
        _ = run(&agc, (0..<Int(20 * sr)).map { _ in a * noise() })
        XCTAssertEqual(agc.gainDB, 8, accuracy: 0.5)
    }

    func testShoutingWithHighGainNeverClips() {
        var agc = hush_agc_t()
        hush_agc_init(&agc, sr, 24)
        let y = run(&agc, speech(seconds: 3, speechDB: -8))
        XCTAssertLessThanOrEqual(y.map(abs).max()!, 1.0)
    }

    func testAdaptsQuicklyToALouderSpeaker() {
        var agc = hush_agc_t()
        hush_agc_init(&agc, sr, 0)
        _ = run(&agc, speech(seconds: 12, speechDB: -42))
        XCTAssertGreaterThan(agc.gainDB, 12, "voix faible : gain élevé")
        _ = run(&agc, speech(seconds: 2, speechDB: -14))
        XCTAssertLessThan(agc.gainDB, 2, "voix forte : gain redescendu en moins de 2 s")
    }
}

final class DriftResampleTests: XCTestCase {
    /// drift correction must not create any discontinuity: edges kept, signal smooth
    func testDropAndAddKeepEdgesAndSmoothness() {
        let n = 256
        let src = (0..<n).map { sinf(2 * .pi * 440 * Float($0) / 48000) }
        for m in [n - 1, n + 1] {
            var dst = [Float](repeating: 0, count: m)
            hush_rt_resample_linear(src, UInt32(n), &dst, UInt32(m))
            XCTAssertEqual(dst.first!, src.first!, accuracy: 1e-6)
            XCTAssertEqual(dst.last!, src.last!, accuracy: 1e-6)
            let maxStep = zip(dst, dst.dropFirst()).map { abs($1 - $0) }.max()!
            let maxSrcStep = zip(src, src.dropFirst()).map { abs($1 - $0) }.max()!
            XCTAssertLessThan(maxStep, maxSrcStep * 1.02, "pas de saut plus grand que dans le signal d'origine")
        }
    }
}

final class DriftEstimatorTests: XCTestCase {
    /// simulates a mic `ppm` off 48 kHz (256 blocks, timestamps w/ ±0.5 ms jitter) for `seconds`
    private func slips(ppm: Double, seconds: Double) -> (dropped: Int, added: Int, estimate: Double) {
        var d = hush_drift_t()
        hush_drift_reset(&d)
        let ticksPerSecond = 1e9, rate = 48000 * (1 + ppm * 1e-6)
        var frames = 0.0, dropped = 0, added = 0
        var seed: UInt32 = 7
        while frames / rate < seconds {
            seed = seed &* 1664525 &+ 1013904223
            let jitter = (Double(seed >> 8) / Double(1 << 24) - 0.5) * 0.001
            let host = UInt64((1 + frames / rate + jitter) * ticksPerSecond)
            let r = hush_drift_update(&d, host, 256, ticksPerSecond)
            if r < 0 { dropped += 1 } else if r > 0 { added += 1 }
            frames += 256
        }
        return (dropped, added, d.ppm)
    }

    func testFastMicrophoneDropsExactlyItsExcess() {
        let r = slips(ppm: 100, seconds: 60)
        XCTAssertEqual(r.estimate, 100, accuracy: 2)
        // corrections from 10 s on: 50 s × 4.8 frames/s ~ 240
        XCTAssertEqual(Double(r.dropped), 240, accuracy: 10)
        XCTAssertEqual(r.added, 0)
    }

    func testSlowMicrophoneAddsSamples() {
        let r = slips(ppm: -50, seconds: 60)
        XCTAssertEqual(Double(r.added), 120, accuracy: 8)
        XCTAssertEqual(r.dropped, 0)
    }

    func testLockedClockNeverCorrectsDespiteJitter() {
        let r = slips(ppm: 0, seconds: 120)
        XCTAssertLessThanOrEqual(r.dropped + r.added, 1, "la gigue ne déclenche aucune correction")
    }
}

final class LevelMeterTests: XCTestCase {
    func testFastAttackSlowRelease() {
        let s = LevelMeter.Smoother()
        let t0 = Date()
        let loud = s.update(db: -6, at: t0.addingTimeInterval(0.016))
        XCTAssertEqual(loud.db, -6, accuracy: 0.01, "attaque instantanée")
        let after = s.update(db: -60, at: t0.addingTimeInterval(0.116))
        XCTAssertEqual(after.db, -9, accuracy: 0.5, "retombée de 30 dB/s")
        XCTAssertEqual(after.peakFraction, (-6 + 60) / 60, accuracy: 0.01, "crête maintenue")
    }

    func testClampsRange() {
        let s = LevelMeter.Smoother()
        XCTAssertEqual(s.update(db: 12, at: Date().addingTimeInterval(0.01)).fraction, 1)
    }
}

final class DeviceTests: XCTestCase {
    func testHushMicrophoneIsNeverOfferedAsSource() {
        XCTAssertFalse(AudioDevices.inputDevices().contains { $0.uid == AudioDevices.hushDeviceUID })
    }

    func testErrorsHaveHumanMessages() {
        let all: [HushError] = [.microphonePermissionDenied, .noInputDevice, .virtualMicrophoneMissing, .sharedMemoryUnavailable,
                                .voiceProcessingFailed, .anotherInstanceRunning, .installCancelled, .installFailed, .uninstallFailed]
        for e in all {
            XCTAssertFalse(e.title.isEmpty)
            XCTAssertFalse(e.advice.isEmpty)
            XCTAssertFalse(e.advice.contains("OSStatus"))
        }
    }
}
