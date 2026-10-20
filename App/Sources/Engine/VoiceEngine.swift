#if canImport(HushRT)
import HushRT
#endif
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Configure et pilote les audio units. Tout le traitement temps réel est en C (hush_rt.c).
/// À utiliser depuis un seul thread (le thread principal, via EngineController).
final class VoiceEngine {
    static let sampleRate = 48000.0
    private static let log = Logger(subsystem: "io.github.showdown76py.Hush", category: "engine")

    let rt: OpaquePointer
    private var vpUnit: AudioUnit?
    private var rawUnit: AudioUnit?
    private(set) var isRunning = false
    private(set) var isMonitoringRaw = false
    private var shm: UnsafeMutableRawPointer?

    init() {
        guard let rt = hush_rt_create() else { fatalError("mémoire insuffisante") }
        self.rt = rt
    }

    deinit {
        stop()
        stopRawMonitor()
        hush_rt_destroy(rt)
    }

    struct Configuration: Equatable {
        var inputDevice: AudioDeviceID
        var keepAppleDucking: Bool
        var ioBufferFrames: UInt32 = 256
    }

    private static func monoFormat() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr {
            log.error("\(what, privacy: .public) a échoué : \(status)")
            throw HushError.voiceProcessingFailed
        }
    }

    private static func makeUnit(_ subType: OSType) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: subType,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw HushError.voiceProcessingFailed }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unit), "AudioComponentInstanceNew")
        return unit!
    }

    /// Démarre la capture avec voice processing. `shm` : mémoire partagée avec le driver (peut être nil).
    func start(_ config: Configuration, shm: UnsafeMutableRawPointer?) throws {
        stop()
        setPassthrough(nil)   // un seul producteur dans le ring
        // Buffers IO courts pour ce processus : moins de latence (sans effet sur les autres apps).
        AudioDevices.setBufferFrameSize(config.inputDevice, config.ioBufferFrames)
        if let output = AudioDevices.defaultDevice(input: false) {
            AudioDevices.setBufferFrameSize(output, config.ioBufferFrames)
        }

        let unit = try Self.makeUnit(kAudioUnitSubType_VoiceProcessingIO)
        do {
            var one: UInt32 = 1
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "EnableIO")
            var dev = config.inputDevice
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &dev,
                                                UInt32(MemoryLayout<AudioDeviceID>.size)), "CurrentDevice")
            // Ducking des autres apps : minimum possible (-8 dB, plancher de macOS) sauf si l'utilisateur
            // préfère le comportement d'Apple.
            var duck = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false,
                                                               mDuckingLevel: config.keepAppleDucking ? .default : .min)
            try Self.check(AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
                                                &duck, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)), "Ducking")
            // Pas de gain automatique : quand la musique est forte, il remonte le résidu de suppression
            // (souffle « ventilateur »). Un gain fixe est appliqué à la place dans hush_rt.
            var agc: UInt32 = 0
            try Self.check(AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0,
                                                &agc, UInt32(MemoryLayout<UInt32>.size)), "AGC")
            var fmt = Self.monoFormat()
            let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, fmtSize), "format micro")
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, fmtSize), "format sortie")
            let refCon = UnsafeMutableRawPointer(rt)
            var input = AURenderCallbackStruct(inputProc: hush_rt_vp_input, inputProcRefCon: refCon)
            var output = AURenderCallbackStruct(inputProc: hush_rt_silence_output, inputProcRefCon: refCon)
            let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &input, cbSize), "callback micro")
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &output, cbSize), "callback sortie")
            hush_rt_set_vp_unit(rt, unit)
            self.shm = shm
            hush_rt_set_shm(rt, shm)
            try Self.check(AudioUnitInitialize(unit), "AudioUnitInitialize")
            try Self.check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
        vpUnit = unit
        isRunning = true
        Self.log.notice("voice processing démarré (entrée \(config.inputDevice), ducking Apple : \(config.keepAppleDucking))")
    }

    func stop() {
        guard let unit = vpUnit else { return }
        hush_rt_set_shm(rt, nil)
        if let shm { hush_app_stop(shm) }   // le driver passe au silence tout de suite
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        vpUnit = nil
        isRunning = false
        // Une unité brute ouverte pendant le voice processing reste dans le mode « altéré » de macOS
        // (environ 10 dB plus bas) : elle sera rouverte à sa prochaine utilisation.
        rawUnitIsStale = rawUnit != nil
        Self.log.notice("voice processing arrêté")
    }

    /// Niveau de la voix traitée : gain automatique piloté par la voix, ou gain fixe (dB).
    func setVoiceLevel(automatic: Bool, fixedDB: Float) {
        hush_rt_set_gain_db(rt, fixedDB)
        hush_rt_set_auto_gain(rt, automatic ? 1 : 0)
    }

    /// Repart du gain automatique mémorisé (appelé à chaque démarrage du traitement).
    func resetAutomaticGain(to dB: Float) {
        hush_rt_reset_auto_gain(rt, dB)
    }

    var automaticGainDB: Float { hush_rt_auto_gain_db(rt) }

    func setSharedMemory(_ shm: UnsafeMutableRawPointer?) {
        self.shm = shm
        if isRunning { hush_rt_set_shm(rt, shm) }
    }

    private(set) var rawDevice: AudioDeviceID?
    private(set) var isPassingThrough = false
    private var rawUnitIsStale = false

    /// Micro brut envoyé tel quel au driver ("micro propre" désactivé). Exclusif avec `start`.
    func setPassthrough(_ shm: UnsafeMutableRawPointer?) {
        precondition(shm == nil || !isRunning, "un seul producteur à la fois")
        hush_rt_set_passthrough(rt, shm)
        if shm == nil, isPassingThrough, let s = shmForPassthrough { hush_app_stop(s) }   // driver → silence
        shmForPassthrough = shm
        isPassingThrough = shm != nil
        Self.log.notice("passage direct : \(shm != nil ? "actif" : "arrêté", privacy: .public)")
    }
    private var shmForPassthrough: UnsafeMutableRawPointer?

    /// Capture parallèle du micro sans traitement (vumètre "micro", enregistrement "sans Hush",
    /// passage direct). Sans effet si elle tourne déjà sur ce périphérique.
    func startRawMonitor(device: AudioDeviceID) throws {
        if rawUnit != nil, rawDevice == device, !rawUnitIsStale { return }
        rawUnitIsStale = false
        stopRawMonitor()
        AudioDevices.setBufferFrameSize(device, 256)
        let unit = try Self.makeUnit(kAudioUnitSubType_HALOutput)
        do {
            var one: UInt32 = 1, zero: UInt32 = 0
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "raw EnableIO in")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "raw EnableIO out")
            var dev = device
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                                UInt32(MemoryLayout<AudioDeviceID>.size)), "raw device")
            var fmt = Self.monoFormat()
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "raw format")
            var map: [Int32] = [0]
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &map, 4)
            var cb = AURenderCallbackStruct(inputProc: hush_rt_raw_input, inputProcRefCon: UnsafeMutableRawPointer(rt))
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                                UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "raw callback")
            hush_rt_set_raw_unit(rt, unit)
            try Self.check(AudioUnitInitialize(unit), "raw init")
            try Self.check(AudioOutputUnitStart(unit), "raw start")
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
        rawUnit = unit
        rawDevice = device
        isMonitoringRaw = true
    }

    func stopRawMonitor() {
        guard let unit = rawUnit else { return }
        rawDevice = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        rawUnit = nil
        isMonitoringRaw = false
    }

    // MARK: - État temps réel

    var cleanLevel: Float { hush_rt_level_clean(rt) }
    var rawLevel: Float { hush_rt_level_raw(rt) }
    var callbackCount: UInt64 { hush_rt_vp_callbacks(rt) }
    var errorCount: UInt64 { hush_rt_vp_errors(rt) }
    var driftSlips: Int64 { hush_rt_drift_slips(rt) }
}
