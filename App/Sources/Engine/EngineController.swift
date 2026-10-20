import AppKit
import AVFoundation
import Combine
import CoreAudio
import os

/// Quand le voice processing doit tourner.
enum HushMode: String, CaseIterable, Identifiable {
    case automatic   // seulement quand une app utilise "Hush Microphone"
    case always
    case off
    var id: String { rawValue }
}

/// Cerveau de l'app : décide quand lancer le traitement, surveille les changements matériels
/// (écouteurs, AirPods, fréquence, veille, redémarrage de coreaudiod) et relance automatiquement.
@MainActor
final class EngineController: ObservableObject {
    enum Status: Equatable {
        case off                 // désactivé par l'utilisateur
        case waiting             // mode auto, aucune app n'utilise le micro
        case starting
        case running
        case problem(HushError)
    }

    @Published private(set) var status: Status = .off
    private func setStatus(_ new: Status) { if status != new { status = new } }
    @Published private(set) var sourceName: String = ""
    @Published private(set) var clientCount = 0
    @Published private(set) var driverState: DriverInstaller.State = DriverInstaller.state
    @Published var mode: HushMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode); reconcile() }
    }
    @Published var sourceUID: String {
        didSet { UserDefaults.standard.set(sourceUID, forKey: Keys.source); scheduleRestart(reason: "source") }
    }
    @Published var keepAppleDucking: Bool {
        didSet { UserDefaults.standard.set(keepAppleDucking, forKey: Keys.ducking); scheduleRestart(reason: "ducking") }
    }
    @Published var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Keys.onboarding) }
    }

    enum Keys {
        static let mode = "mode", source = "sourceUID", ducking = "keepAppleDucking", onboarding = "onboardingCompleted"
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
    private var lastCallbackProgress = Date()
    private var failures = 0
    private var nextRetry = Date.distantPast
    private var sleeping = false
    /// Forcé par l'onboarding (test avant/après) même en mode auto.
    @Published var forceRunning = false { didSet { reconcile() } }
    /// Coupe le traitement pendant la partie "sans Hush" du test avant/après.
    @Published var suspendedForTest = false { didSet { reconcile() } }
    private var activeDevice: AudioDeviceID?

    init() {
        let d = UserDefaults.standard
        mode = HushMode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .automatic
        sourceUID = d.string(forKey: Keys.source) ?? ""
        keepAppleDucking = d.bool(forKey: Keys.ducking)
        onboardingCompleted = d.bool(forKey: Keys.onboarding)
        guard !isHeadless else { return }   // pas d'audio ni de mémoire partagée (tests, captures d'écran)
        shm = try? SharedMemory()
        installListeners()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        reconcile()
    }

    // MARK: - Décision

    private var wantsRunning: Bool {
        if sleeping || suspendedForTest { return false }
        if forceRunning { return true }
        switch mode {
        case .off: return false
        case .always: return true
        case .automatic:
            // Hystérésis : on garde le traitement 3 s après le départ du dernier client.
            return clientCount > 0 || Date().timeIntervalSince(lastClientSeen) < 3
        }
    }

    var microphonePermission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Aligne l'état réel sur l'état voulu.
    func reconcile() {
        if !wantsRunning {
            if engine.isRunning { engine.stop() }
            failures = 0
            setStatus(mode == .off ? .off : .waiting)
            return
        }
        if engine.isRunning { return }
        guard Date() >= nextRetry else { return }
        start()
    }

    private func start() {
        guard microphonePermission == .authorized else {
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

    /// Relance (débouncée) après un changement matériel ou de réglage.
    func scheduleRestart(reason: String, delay: TimeInterval = 0.5) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log.info("relance : \(reason, privacy: .public)")
                if self.engine.isRunning { self.engine.stop() }
                self.nextRetry = .distantPast
                self.reconcile()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Surveillance périodique

    private func tick() {
        if let stats = shm?.stats {
            if stats.clients != clientCount { clientCount = stats.clients }
            if stats.clients > 0 { lastClientSeen = Date() }
        }
        if engine.isRunning {
            // Chien de garde : plus aucun callback audio depuis 1,5 s → relance.
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

    // MARK: - Événements système

    private func installListeners() {
        let sys = AudioDevices.system
        let restartSelectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,   // écouteurs, AirPods…
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices,               // branchement / débranchement
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
        guard engine.isRunning else { return }
        if selector == kAudioHardwarePropertyDevices {
            // On ne relance que si notre micro a disparu ou si un micro préféré vient d'apparaître.
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

    // MARK: - Popover

    /// Le vumètre "micro" n'écoute le micro que pendant que le popover est ouvert.
    var popoverVisible = false {
        didSet { updateRawMonitor() }
    }

    func updateRawMonitor() {
        guard popoverVisible, let source = AudioDevices.resolveSource(preferredUID: sourceUID),
              microphonePermission == .authorized else {
            engine.stopRawMonitor()
            return
        }
        try? engine.startRawMonitor(device: source.id)
    }

    /// Quand le voice processing tourne, macOS remet aux autres clients du même micro un signal
    /// environ 17 dB plus faible (mesuré sur MacBook Air) : on compense pour l'affichage.
    var rawMeterOffsetDB: Float { engine.isRunning ? 17 : 0 }

    // Niveaux des vumètres (remplaçables par des valeurs de démonstration pour les captures).
    var previewLevels: (raw: Float, clean: Float)?
    func rawMeterLevel() -> Float { previewLevels?.raw ?? engine.rawLevel }
    func cleanMeterLevel() -> Float { previewLevels?.clean ?? (engine.isRunning ? engine.cleanLevel : 0) }

    /// État de démonstration (captures d'écran uniquement).
    func applyPreview(status: Status, clients: Int, source: String, levels: (raw: Float, clean: Float)) {
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
        case .off: String(localized: "Off")
        case .problem(let e): e.title
        }
    }

    // MARK: - Actions

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
