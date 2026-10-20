import AVFoundation
import SwiftUI

/// Premier lancement : 5 écrans courts.
struct OnboardingView: View {
    @EnvironmentObject private var controller: EngineController
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step: Int
    private let stepCount = 5

    init(initialStep: Int = 0) { _step = State(initialValue: initialStep) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: WelcomeStep(next: next)
                case 1: PermissionStep(next: next)
                case 2: InstallStep(next: next)
                case 3: TestStep(next: next)
                default: DiscordGuideView(showsDoneButton: true, done: finish)
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 40)
            .padding(.bottom, 24)

            HStack(spacing: 7) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: i == step ? 18 : 7, height: 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .hushGlass(in: Capsule())
            .padding(.bottom, 18)
            .accessibilityHidden(true)
        }
        .frame(width: 600, height: 540)
        .animation(.spring(duration: 0.45), value: step)
    }

    private func next() { step = min(step + 1, stepCount - 1) }

    private func finish() {
        controller.onboardingCompleted = true
        dismissWindow(id: WindowID.onboarding)
    }
}

// MARK: - Étapes

private struct StepHeader: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.accentColor.gradient)
                .symbolRenderingMode(.hierarchical)
                .frame(height: 56)
            Text(title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    let next: () -> Void
    var body: some View {
        VStack(spacing: 28) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(radius: 12, y: 6)
            VStack(spacing: 12) {
                Text("Welcome to Hush").font(.largeTitle.weight(.bold))
                Text("Your friends hear your voice — not the music or videos playing on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button("Get started", action: next)
                .hushGlassButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct PermissionStep: View {
    let next: () -> Void
    @EnvironmentObject private var controller: EngineController
    @State private var status = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(symbol: "mic.circle", title: "Allow the microphone",
                       subtitle: "Hush listens to your microphone, removes the sound of your speakers, and passes your voice on. Nothing is recorded or sent anywhere.")
            Spacer()
            switch status {
            case .authorized:
                Label("Microphone allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Continue", action: next).hushGlassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction)
            case .denied, .restricted:
                Text("Microphone access was refused. Turn on Hush in System Settings › Privacy & Security › Microphone.")
                    .multilineTextAlignment(.center).foregroundStyle(.orange)
                HStack {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    Button("Check again") { status = AVCaptureDevice.authorizationStatus(for: .audio) }
                }
                .hushGlassButton()
                .controlSize(.large)
            default:
                Button("Allow microphone") {
                    Task {
                        _ = await controller.requestMicrophoneAccess()
                        status = AVCaptureDevice.authorizationStatus(for: .audio)
                        if status == .authorized { next() }
                    }
                }
                .hushGlassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct InstallStep: View {
    let next: () -> Void
    @EnvironmentObject private var controller: EngineController
    @State private var working = false
    @State private var error: HushError?

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(symbol: "waveform.badge.plus", title: "Install the Hush microphone",
                       subtitle: "Hush adds a microphone called “Hush Microphone” that Discord, Zoom, Meet or OBS can use. macOS will ask for your password once.")
            Spacer()
            if let error {
                VStack(spacing: 4) {
                    Text(error.title).font(.headline).foregroundStyle(.orange)
                    Text(error.advice).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            if controller.driverState == .installed {
                Label("Hush Microphone is installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Continue", action: next).hushGlassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                Button {
                    working = true
                    error = nil
                    Task {
                        do { try await controller.installDriver() } catch { self.error = error as? HushError ?? .installFailed }
                        working = false
                        if controller.driverState == .installed { next() }
                    }
                } label: {
                    if working { ProgressView().controlSize(.small).padding(.horizontal, 30) }
                    else { Text(controller.driverState == .updateAvailable ? "Update" : "Install") }
                }
                .hushGlassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .onAppear { controller.refreshDriverState() }
    }
}

private struct TestStep: View {
    let next: () -> Void
    @EnvironmentObject private var controller: EngineController
    @StateObject private var test = BeforeAfterTest()

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "music.note.house", title: "Hear the difference",
                       subtitle: "Play some music on your speakers, press Start, and keep talking for 10 seconds.")
            Spacer()
            switch test.phase {
            case .idle, .failed:
                if test.phase == .failed {
                    Text("The test couldn’t record. Check that the microphone is allowed, then try again.")
                        .foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                Button("Start the test") { Task { await test.run(controller: controller) } }
                    .hushGlassButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction)
                Button("Skip", action: next).buttonStyle(.link)
            case .warmingUp(let remaining):
                Text("Start talking… \(remaining)").font(.title2.monospacedDigit())
            case .recordingWith, .recordingWithout:
                VStack(spacing: 10) {
                    Text(test.phase == .recordingWith ? "Recording with Hush…" : "Recording without Hush…")
                        .font(.title3.weight(.semibold))
                    ProgressView(value: test.progress).frame(width: 320)
                    Text("Keep talking").foregroundStyle(.secondary)
                }
            case .done:
                HStack(spacing: 16) {
                    PlayCard(title: "Without Hush", subtitle: "What your friends heard before",
                             symbol: "speaker.wave.3", isPlaying: test.playing == .without) { test.play(.without) }
                    PlayCard(title: "With Hush", subtitle: "What they hear now",
                             symbol: "sparkles", isPlaying: test.playing == .with) { test.play(.with) }
                }
                HStack {
                    Button("Try again") { Task { await test.run(controller: controller) } }
                        .hushGlassButton()
                    Button("Continue") { test.stopPlayback(); next() }
                        .hushGlassButton(prominent: true).keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
        }
        .onDisappear { test.stopPlayback() }
    }
}

private struct PlayCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : symbol)
                    .font(.system(size: 28))
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    .frame(height: 34)
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(width: 190, height: 130)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .hushGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                       tint: isPlaying ? .accentColor.opacity(0.35) : nil, interactive: true)
        }
        .buttonStyle(.plain)
    }
}
