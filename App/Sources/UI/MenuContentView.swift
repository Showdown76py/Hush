import SwiftUI

/// Contenu du popover de la barre de menus.
struct MenuContentView: View {
    @EnvironmentObject private var controller: EngineController
    @EnvironmentObject private var updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HushGlassContainer(spacing: 4) {
        VStack(alignment: .leading, spacing: 14) {
            header
            PowerToggle(isOn: Binding(
                get: { controller.mode != .off },
                set: { controller.mode = $0 ? .automatic : .off }))
            if controller.mode != .off {
                Picker("", selection: $controller.mode) {
                    Text("Automatic").tag(HushMode.automatic)
                    Text("Always on").tag(HushMode.always)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if case .problem(let error) = controller.status {
                ProblemBanner(error: error)
            }
            meters
                .padding(14)
                .hushGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            footer
        }
        }
        .padding(16)
        .frame(width: 320)
        .animation(.spring(duration: 0.35), value: controller.mode)
        .animation(.spring(duration: 0.35), value: controller.status)
        .onAppear { controller.popoverVisible = true }
        .onDisappear { controller.popoverVisible = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hush").font(.headline)
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            StatusDot(status: controller.status)
        }
    }

    private var meters: some View {
        VStack(spacing: 12) {
            LevelMeter(title: "Microphone", systemImage: "waveform", tint: .orange,
                       level: { controller.rawMeterLevel() }, offsetDB: controller.rawMeterOffsetDB)
            LevelMeter(title: "Sent to apps", systemImage: "checkmark.seal.fill", tint: .green,
                       level: { controller.cleanMeterLevel() })
            if !controller.sourceName.isEmpty {
                Label(controller.sourceName, systemImage: "mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { openWindow(id: WindowID.discord); NSApp.activate(ignoringOtherApps: true) } label: {
                Label("Discord setup", systemImage: "headphones")
            }
            Spacer()
            Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                .help(Text("Settings…"))
                .buttonBorderShape(.circle)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help(Text("Quit Hush"))
                .buttonBorderShape(.circle)
        }
        .hushGlassButton()
        .controlSize(.large)
    }
}

/// Gros interrupteur principal.
struct PowerToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 14) {
                Image(systemName: isOn ? "waveform.badge.mic" : "mic.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOn ? .white : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.hushBrand.gradient).opacity(isOn ? 1 : 0))
                    .hushGlass(in: Circle(), tint: isOn ? Color.hushBrand : nil, interactive: true)
                    .shadow(color: isOn ? Color.hushBrand.opacity(0.45) : .clear, radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOn ? "Clean microphone on" : "Clean microphone off")
                        .font(.title3.weight(.semibold))
                    Text(isOn ? "Music from your speakers is removed" : "Your Mac sounds exactly as usual")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .hushGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }
}

struct StatusDot: View {
    let status: EngineController.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 4).scaleEffect(status == .running ? 1.6 : 1))
            .symbolEffect(.pulse, isActive: status == .running)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .starting: .yellow
        case .waiting: .blue
        case .off: .gray
        case .problem: .orange
        }
    }
}

struct ProblemBanner: View {
    let error: HushError
    @EnvironmentObject private var controller: EngineController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(error.advice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
                    .hushGlassButton(prominent: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hushGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .orange.opacity(0.18))
    }

    private var action: (title: LocalizedStringKey, run: () -> Void)? {
        switch error {
        case .microphonePermissionDenied:
            return ("Open Privacy Settings", {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            })
        case .virtualMicrophoneMissing:
            return ("Install", { Task { try? await controller.installDriver() } })
        default:
            return nil
        }
    }
}
