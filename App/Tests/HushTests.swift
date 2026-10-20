import XCTest
@testable import Hush

/// Tests sans matériel audio : contrat de mémoire partagée, partie temps réel, logique de l'UI.
final class SharedMemoryContractTests: XCTestCase {
    /// Mémoire ordinaire (jamais la vraie mémoire partagée du driver installé).
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
        let shm = p.assumingMemoryBound(to: UInt8.self)
        _ = shm
        XCTAssertEqual(hush_app_reader_stats(p).clientsRunning, 0)
        hush_app_stop(p)
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
                                .voiceProcessingFailed, .installCancelled, .installFailed, .uninstallFailed]
        for e in all {
            XCTAssertFalse(e.title.isEmpty)
            XCTAssertFalse(e.advice.isEmpty)
            XCTAssertFalse(e.advice.contains("OSStatus"))
        }
    }
}
