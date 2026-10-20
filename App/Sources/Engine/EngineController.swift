import AppKit
import AVFoundation
import Combine
import CoreAudio
import os

enum HushMode: String, CaseIterable, Identifiable {
    case automatic   // only when an app uses "Hush Microphone"
    case always
    case off
    var id: String { rawValue }
}

/// decides when processing runs and restarts it after hw changes (headphones, airpods
/// sample rate, sleep, coreaudiod restart)
@MainActor
final class EngineController: ObservableObject {
    enum Status: Equatable {
        case off                 // turned off by the user
        case waiting             // auto mode, no app using the mic
        case starting
        case running
        case problem(HushError)
    }

    @Published private(set) var status: Status = .off
    private func setStatus(_ new: Status) { if status != new { status = new } }
    @Published private(set) var sourceName: String = ""
    @Published private(set) var clientCount = 0
    /// "clean mic" off but an app is listening so raw mic is passed through as is
    @Published private(set) var passthroughActive = false
    private var passthroughError: HushError?
    @Published private(set) var driverState: DriverInstaller.State = DriverInstaller.state
    @Published var mode: HushMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            log.notice("mode : \(self.mode.rawValue, privacy: .public)")
            reconcile()
        }
    }
    @Published var sourceUID: String {
        didSet { UserDefaults.standard.set(sourceUID, forKey: Keys.source); scheduleRestart(reason: "source") }
    }
    @Published var keepAppleDucking: Bool {
        didSet { UserDefaults.standard.set(keepAppleDucking, forKey: Keys.ducking); scheduleRestart(reason: "ducking") }
    }
    /// voice level: "auto" (voice driven agc) or a fixed gain in dB ("0", "6"…)
    @Published var voiceLevel: String {
        didSet {
            UserDefaults.standard.set(voiceLevel, forKey: Keys.voiceLevel)
            applyVoiceLevel()
        }
    }
    @Published var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Keys.onboarding) }
    }

    /// agc starting gain before a session has stored its own
    static let defaultAutomaticGainDB: Float = 10

    enum Keys {
        static let mode = "mode", source = "sourceUID", ducking = "keepAppleDucking", onboarding = "onboardingCompleted"
        static let voiceLevel = "voiceLevel", automaticGain = "automaticGainDB"
    }

    let engine = VoiceEngine()
    private var shm: SharedMemory?
    private let log = Logger(subsystem: "io.github.showdown76py.Hush", category: "controller")
    private var listeners: [AudioPropertyListener] = []
    private var deviceListeners: [AudioPropertyListener] = []
    private var timer: Timer?
    private var restartWork: DispatchWorkItem?
    private var lastClientSeen = Date.distantPast
    private var lastCallbackCount: UInt64 = 0
    private var lastGainSave = Date()
    private var lastCallbackProgress = Date()
    private var failures = 0
    private var nextRetry = Date.distantPast
    private var sleeping = false
    /// forced by onboarding (before/after test) even in auto mode
    @Published var forceRunning = false { didSet { reconcile() } }
    /// cuts processing during the "without hush" part of the before/after test
    @Published var suspendedForTest = false { didSet { reconcile() } }
    private var activeDevice: AudioDeviceID?

    init() {
        let d = UserDefaults.standard
        mode = HushMode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .automatic
        sourceUID = d.string(forKey: Keys.source) ?? ""
        keepAppleDucking = d.bool(forKey: Keys.ducking)
        voiceLevel = d.string(forKey: Keys.voiceLevel) ?? "auto"
        onboardingCompleted = d.bool(forKey: Keys.onboarding)
        applyVoiceLevel()
        guard !isHeadless else { return }   // no audio or shm (tests, screenshots)
        shm = try? SharedMemory()
        installListeners()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        reconcile()
    }

    private var wantsRunning: Bool {
        if sleeping || suspendedForTest { return false }
        if forceRunning { return true }
        switch mode {
        case .off: return false
        case .always: return true
        case .automatic:
            return hasRecentClient
        }
    }

    /// 3 s hysteresis after the last client leaves
    private var hasRecentClient: Bool {
        clientCount > 0 || Date().timeIntervalSince(lastClientSeen) < 3
    }

    var microphonePermission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    func reconcile() {
        if !wantsRunning {
            if engine.isRunning { saveAutomaticGain(); engine.stop() }
            failures = 0
            updatePassthrough()
            if let passthroughError { setStatus(.problem(passthroughError)) } else { setStatus(mode == .off ? .off : .waiting) }
            return
        }
        if engine.isPassingThrough { stopPassthrough() }
        if engine.isRunning { return }
        guard Date() >= nextRetry else { return }
        start()
    }

    private func start() {
        switch microphonePermission {
        case .authorized:
            break
        case .notDetermined:
            // app replaced by a build w/ a different signature
            requestMicrophoneAccessOnce()
            setStatus(.starting)
            return
        default:
            setStatus(.problem(.microphonePermissionDenied))
            return
        }
        guard let source = AudioDevices.resolveSource(preferredUID: sourceUID) else {
            setStatus(.problem(.noInputDevice))
            return
        }
        if shm == nil { shm = try? SharedMemory() }
        setStatus(.starting)
        do {
            let savedGain = UserDefaults.standard.object(forKey: Keys.automaticGain) as? Float ?? Self.defaultAutomaticGainDB
            engine.resetAutomaticGain(to: savedGain)
            try engine.start(.init(inputDevice: source.id, keepAppleDucking: keepAppleDucking), shm: shm?.pointer)
            sourceName = source.name
            activeDevice = source.id
            watchDevice(source.id)
            updateRawMonitor()
            failures = 0
            lastCallbackCount = engine.callbackCount
            lastCallbackProgress = Date()
            setStatus(driverState == .notInstalled ? .problem(.virtualMicrophoneMissing) : .running)
        } catch {
            failures += 1
            let delays: [TimeInterval] = [1, 2, 5, 10, 30]
            nextRetry = Date().addingTimeInterval(delays[min(failures - 1, delays.count - 1)])
            log.error("échec du démarrage (\(self.failures)) : \(String(describing: error), privacy: .public)")
            setStatus(.problem(error as? HushError ?? .voiceProcessingFailed))
        }
    }

    private func applyVoiceLevel() {
        engine.setVoiceLevel(automatic: voiceLevel == "auto", fixedDB: Float(voiceLevel) ?? 0)
    }

    private func saveAutomaticGain() {
        guard voiceLevel == "auto" else { return }
        UserDefaults.standard.set(engine.automaticGainDB, forKey: Keys.automaticGain)
    }

    private var wantsPassthrough: Bool {
        mode == .off && !forceRunning && !suspendedForTest && !sleeping && microphonePermission == .authorized
            && hasRecentClient
    }

    /// raw mic only opened if an app listens to Hush Microphone (else macOS orange
    /// indicator stays on forever)
    private func updatePassthrough() {
        guard wantsPassthrough, let shm, let source = AudioDevices.resolveSource(preferredUID: sourceUID) else {
            if engine.isPassingThrough { stopPassthrough() }
            passthroughError = nil
            return
        }
        guard !engine.isPassingThrough || engine.rawDevice != source.id else { return }
        do {
            if engine.isPassingThrough { try? engine.setPassthrough(nil) }   // mic changed
            try engine.startRawMonitor(device: source.id)
            try engine.setPassthrough(shm.pointer)
            sourceName = source.name
            activeDevice = source.id
            watchDevice(source.id)
            passthroughActive = true
            passthroughError = nil
        } catch {
            log.error("passage direct impossible : \(String(describing: error), privacy: .public)")
            passthroughError = error as? HushError
        }
    }

    private func stopPassthrough() {
        try? engine.setPassthrough(nil)
        passthroughActive = false
        updateRawMonitor()   // cuts the mic if popover is closed
    }

    func scheduleRestart(reason: String, delay: TimeInterval = 0.5) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log.notice("relance : \(reason, privacy: .public)")
                if self.engine.isRunning { self.engine.stop() }
                if self.engine.isPassingThrough {
                    try? self.engine.setPassthrough(nil)
                    self.engine.stopRawMonitor()
                    self.passthroughActive = false
                }
                self.nextRetry = .distantPast
                self.reconcile()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func tick() {
        if let stats = shm?.stats {
            if stats.clients != clientCount {
                log.notice("apps clientes de Hush Microphone : \(stats.clients)")
                clientCount = stats.clients
            }
            if stats.clients > 0 { lastClientSeen = Date() }
        }
        if engine.isRunning, Date().timeIntervalSince(lastGainSave) > 10 {
            saveAutomaticGain()
            lastGainSave = Date()
        }
        if engine.isRunning {
            // watchdog: no audio callback for 1.5 s so restart
            let count = engine.callbackCount
            if count != lastCallbackCount {
                lastCallbackCount = count
                lastCallbackProgress = Date()
                if case .problem(.voiceProcessingFailed) = status { setStatus(.running) }
            } else if Date().timeIntervalSince(lastCallbackProgress) > 1.5 {
                log.error("plus de callbacks audio : relance")
                engine.stop()
                failures += 1
                nextRetry = Date().addingTimeInterval(1)
            }
        }
        reconcile()
    }

    private func installListeners() {
        let sys = AudioDevices.system
        let restartSelectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,   // headphones, airpods…
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices,               // plug / unplug
        ]
        for sel in restartSelectors {
            if let l = AudioPropertyListener(object: sys, selector: sel, handler: { [weak self] in
                self?.handleHardwareChange(sel)
            }) { listeners.append(l) }
        }
        if let l = AudioPropertyListener(object: sys, selector: kAudioHardwarePropertyServiceRestarted, handler: { [weak self] in
            self?.log.info("coreaudiod a redémarré")
            self?.driverState = DriverInstaller.state
            self?.scheduleRestart(reason: "coreaudiod", delay: 1.5)
        }) { listeners.append(l) }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = true
                self?.reconcile()
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = false
                self?.scheduleRestart(reason: "réveil", delay: 1.5)
            }
        }
    }

    private func handleHardwareChange(_ selector: AudioObjectPropertySelector) {
        driverState = DriverInstaller.state
        guard engine.isRunning || engine.isPassingThrough else { return }
        if selector == kAudioHardwarePropertyDevices {
            // restart only if our mic vanished or the preferred mic just showed up
            let resolved = AudioDevices.resolveSource(preferredUID: sourceUID)?.id
            guard resolved != activeDevice else { return }
        }
        if selector == kAudioHardwarePropertyDefaultInputDevice, !sourceUID.isEmpty { return }
        scheduleRestart(reason: "matériel")
    }

    private func watchDevice(_ id: AudioDeviceID) {
        deviceListeners = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive].compactMap { sel in
            AudioPropertyListener(object: id, selector: sel) { [weak self] in self?.scheduleRestart(reason: "périphérique") }
        }
    }

    /// "mic" meter only listens to the mic while the popover is open
    var popoverVisible = false {
        didSet { updateRawMonitor() }
    }

    func updateRawMonitor() {
        if engine.isPassingThrough { return }   // raw unit already used for passthrough
        guard popoverVisible, let source = AudioDevices.resolveSource(preferredUID: sourceUID),
              microphonePermission == .authorized else {
            engine.stopRawMonitor()
            return
        }
        try? engine.startRawMonitor(device: source.id)
    }

    /// while vp runs other clients of the same mic get a signal
    /// ~17 dB lower (measured on MacBook Air)
    var rawMeterOffsetDB: Float { engine.isRunning ? 17 : 0 }

    /// demo values for screenshots
    var previewLevels: (raw: Float, clean: Float)?
    func rawMeterLevel() -> Float { previewLevels?.raw ?? engine.rawLevel }
    func cleanMeterLevel() -> Float {
        if let previewLevels { return previewLevels.clean }
        if engine.isRunning { return engine.cleanLevel }
        return engine.isPassingThrough ? engine.rawLevel : 0
    }

    func applyPreview(status: Status, clients: Int, source: String, levels: (raw: Float, clean: Float),
                      driverState: DriverInstaller.State = .installed) {
        self.driverState = driverState
        self.status = status
        clientCount = clients
        sourceName = source
        previewLevels = levels
    }

    var statusText: String {
        switch status {
        case .running where clientCount > 0:
            String(localized: "Active — \(clientCount) app(s) listening")
        case .running: String(localized: "Active")
        case .starting: String(localized: "Starting…")
        case .waiting: String(localized: "Standby — turns on when an app uses Hush Microphone")
        case .off where passthroughActive: String(localized: "Off — apps get your normal microphone")
        case .off: String(localized: "Off")
        case .problem(let e): e.title
        }
    }

    private var requestingPermission = false

    private func requestMicrophoneAccessOnce() {
        guard !requestingPermission else { return }
        requestingPermission = true
        NSApp.activate(ignoringOtherApps: true)   // system dialog has to come to front
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            requestingPermission = false
            reconcile()
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        reconcile()
        return granted
    }

    func installDriver() async throws {
        try await DriverInstaller.install()
        driverState = DriverInstaller.state
        scheduleRestart(reason: "installation", delay: 1)
    }

    func uninstallDriver() async throws {
        engine.stop()
        try await DriverInstaller.uninstall()
        driverState = DriverInstaller.state
        reconcile()
    }

    func refreshDriverState() { driverState = DriverInstaller.state }
}
