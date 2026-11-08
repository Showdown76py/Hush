import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var controller: EngineController
    @EnvironmentObject private var updates: UpdateController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var devices: [AudioInputDevice] = []
    @State private var resolvedSourceName: String?

    var body: some View {
        HushGlassContainer(spacing: 4) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if controller.driverState == .updateAvailable {
                    DriverUpdateBanner()
                }
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
        .onAppear {
            controller.popoverVisible = true
            refreshDevices()
        }
        .onDisappear { controller.popoverVisible = false }
        .onChange(of: controller.sourceUID) { refreshDevices() }
    }

    private func refreshDevices() {
        guard !isHeadless else { return }
        devices = AudioDevices.inputDevices()
        resolvedSourceName = AudioDevices.resolveSource(preferredUID: controller.sourceUID)?.name
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hush").font(.headline)
                Text(controller.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            StatusBadge(status: controller.status)
        }
    }

    private var meters: some View {
        VStack(spacing: 12) {
            LevelMeter(title: "Microphone", systemImage: "waveform", tint: .orange,
                       level: { controller.rawMeterLevel() }, offsetDB: controller.rawMeterOffsetDB)
            if controller.status == .running || controller.passthroughActive {
                LevelMeter(title: "Sent to apps", systemImage: "checkmark.seal.fill", tint: .green,
                           level: { controller.cleanMeterLevel() })
            } else {
                // an empty bar here looked broken
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).frame(width: 16)
                        Text("Sent to apps").font(.callout)
                    }
                    Text(controller.status == .starting ? "Starting…" : controller.mode == .off
                         ? "No app is using Hush Microphone" : "Waiting for an app to use Hush Microphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            microphonePicker
        }
    }

    private var microphonePicker: some View {
        Menu {
            Picker("Microphone", selection: $controller.sourceUID) {
                Text("Automatic (system default)").tag("")
                ForEach(devices) { d in Text(d.name).tag(d.uid) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic").foregroundStyle(.secondary)
                Text(isHeadless ? controller.sourceName : resolvedSourceName ?? controller.sourceName)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator, lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Microphone"))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { openWindow(id: WindowID.guide); NSApp.activate(ignoringOtherApps: true) } label: {
                Label("Use in an app…", systemImage: "square.grid.2x2")
            }
            Spacer()
            // ⏻ quit next to the big on/off toggle read like a second on/off switch
            Menu {
                Button("Settings…") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                if updates.isAvailable {
                    Button("Check for Updates…") { NSApp.activate(ignoringOtherApps: true); updates.checkForUpdates() }
                }
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://hush.showdown.boo")!) }
                Divider()
                Button("Quit Hush") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            // glass button styles don't apply to a Menu so draw the circle like the other buttons
            .hushGlass(in: Circle(), interactive: true)
            .fixedSize()
            .help(Text("More"))
            .accessibilityLabel(Text("More"))
        }
        .hushGlassButton()
        .controlSize(.large)
    }
}

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
                    Text(isOn ? "Echo and background sound removed" : "Apps get your normal microphone")
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

/// state in words + icon, not only a colored dot
struct StatusBadge: View {
    let status: EngineController.Status

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .symbolEffect(.variableColor.iterative, isActive: status == .running)
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(fill))
        .fixedSize()
        .contentTransition(.opacity)
    }

    private var title: LocalizedStringKey {
        switch status {
        case .running: "Active"
        case .starting: "Starting"
        case .waiting: "Standby"
        case .off: "Off"
        case .problem: "Problem"
        }
    }

    private var symbol: String {
        switch status {
        case .running: "waveform"
        case .starting: "ellipsis"
        case .waiting: "minus"
        case .off: "mic.slash.fill"
        case .problem: "exclamationmark.triangle.fill"
        }
    }

    // system green/yellow/orange text on a pale tint fails contrast in light mode so use darker inks
    private var ink: Color {
        switch status {
        case .running: .dynamic(light: (0.09, 0.46, 0.23), dark: (0.45, 0.86, 0.56))
        case .starting: .dynamic(light: (0.52, 0.38, 0.0), dark: (1.0, 0.84, 0.4))
        case .problem: .dynamic(light: (0.68, 0.29, 0.0), dark: (1.0, 0.64, 0.32))
        case .waiting, .off: .secondary
        }
    }

    private var fill: Color {
        switch status {
        case .running: .green.opacity(0.18)
        case .starting: .yellow.opacity(0.22)
        case .problem: .orange.opacity(0.2)
        case .waiting, .off: .secondary.opacity(0.14)
        }
    }
}

extension Color {
    static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
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

struct DriverUpdateBanner: View {
    @EnvironmentObject private var controller: EngineController
    @State private var working = false
    @State private var error: HushError?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Virtual microphone update").font(.callout.weight(.semibold))
                Text(error.map { "\($0.title). \($0.advice)" }
                     ?? String(localized: "This version of Hush includes a newer Hush Microphone. macOS will ask for your password."))
                    .font(.caption)
                    .foregroundStyle(error == nil ? .secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    working = true
                    error = nil
                    Task {
                        do { try await controller.installDriver() } catch { self.error = error as? HushError ?? .installFailed }
                        working = false
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Update") }
                }
                .controlSize(.small)
                .hushGlassButton(prominent: true)
                .disabled(working)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .hushGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .orange.opacity(0.15))
    }
}
