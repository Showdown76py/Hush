import AVFoundation
import SwiftUI

/// vp changes what other clients of the same mic get so we can't
/// record raw and clean at once. record 5 s w/ hush then 5 s without
@MainActor
final class BeforeAfterTest: ObservableObject {
    enum Phase: Equatable {
        case idle
        case warmingUp(remaining: Int)   // let processing converge on the music
        case recordingWith
        case recordingWithout
        case done
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var playing: Version?

    enum Version { case with, without }

    private var withURL: URL?
    private var withoutURL: URL?
    private var player: AVAudioPlayer?
    private let seconds: Double = 5

    func run(controller: EngineController) async {
        let engine = controller.engine
        player?.stop()
        controller.suspendedForTest = false
        controller.forceRunning = true
        defer {
            controller.forceRunning = false
            controller.suspendedForTest = false
            controller.updateRawMonitor()
        }
        for remaining in stride(from: 3, through: 1, by: -1) {
            phase = .warmingUp(remaining: remaining)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard engine.isRunning else { phase = .failed; return }

        phase = .recordingWith
        guard let with = await record(engine: engine, source: 0) else { phase = .failed; return }

        phase = .recordingWithout
        controller.suspendedForTest = true
        guard let source = AudioDevices.resolveSource(preferredUID: controller.sourceUID),
              (try? engine.startRawMonitor(device: source.id)) != nil else { phase = .failed; return }
        try? await Task.sleep(nanoseconds: 300_000_000)   // let the mic settle
        guard let without = await record(engine: engine, source: 1) else { phase = .failed; return }
        engine.stopRawMonitor()

        withURL = Self.writeNormalized(with, name: "hush-with.wav")
        withoutURL = Self.writeNormalized(without, name: "hush-without.wav")
        phase = (withURL != nil && withoutURL != nil) ? .done : .failed
    }

    private func record(engine: VoiceEngine, source: Int32) async -> [Float]? {
        let frames = UInt32(seconds * VoiceEngine.sampleRate)
        hush_rt_record_start(engine.rt, source, frames)
        let deadline = Date().addingTimeInterval(seconds + 3)
        while hush_rt_record_done(engine.rt) == 0 {
            progress = Double(hush_rt_record_progress(engine.rt)) / Double(frames)
            if Date() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        progress = 1
        let buf = hush_rt_record_buffer(engine.rt)
        return Array(UnsafeBufferPointer(start: buf, count: Int(frames)))
    }

    /// peak normalized to -1 dBFS to compare both at equal volume
    private static func writeNormalized(_ samples: [Float], name: String) -> URL? {
        let peak = samples.map(abs).max() ?? 0
        let gain: Float = peak > 1e-4 ? 0.89 / peak : 1
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceEngine.sampleRate, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, v) in samples.enumerated() { buffer.floatChannelData![0][i] = v * gain }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            return url
        } catch {
            return nil
        }
    }

    func play(_ version: Version) {
        player?.stop()
        guard let url = version == .with ? withURL : withoutURL, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        playing = version
        p.play()
        let duration = p.duration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1e9))
            if self.player === p { self.playing = nil }
        }
    }

    func stopPlayback() {
        player?.stop()
        playing = nil
    }
}
