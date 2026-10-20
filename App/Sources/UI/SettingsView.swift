import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: EngineController
    @EnvironmentObject private var updates: UpdateController
    @State private var devices: [AudioInputDevice] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var working = false
    @State private var error: HushError?
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $controller.sourceUID) {
                    Text("Automatic (system default)").tag("")
                    ForEach(devices) { d in Text(d.name).tag(d.uid) }
                }
                Picker("Clean microphone", selection: $controller.mode) {
                    Text("Automatic — only when an app uses it").tag(HushMode.automatic)
                    Text("Always on").tag(HushMode.always)
                    Text("Off").tag(HushMode.off)
                }
            } footer: {
                Text("In Automatic mode, Hush only runs while an app such as Discord is using “Hush Microphone”, so your music sounds normal the rest of the time.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open Hush at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Picker("Voice level", selection: $controller.voiceLevel) {
                    Text("Automatic (recommended)").tag("auto")
                    Text("+0 dB").tag("0")
                    Text("+6 dB").tag("6")
                    Text("+12 dB").tag("12")
                    Text("+18 dB").tag("18")
                }
                Toggle("Lower other sounds while Hush is on", isOn: $controller.keepAppleDucking)
            } footer: {
                Text("Automatic adjusts to your voice only while you speak, so background noise is never boosted. macOS always lowers other sounds a little (about 8 dB) while voice cleanup runs; turn the last option on to use Apple’s stronger default instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Virtual microphone") {
                LabeledContent("Hush Microphone") {
                    switch controller.driverState {
                    case .installed: Text("Installed").foregroundStyle(.green)
                    case .updateAvailable: Text("Update available").foregroundStyle(.orange)
                    case .notInstalled: Text("Not installed").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if controller.driverState != .installed {
                        Button(controller.driverState == .notInstalled ? "Install…" : "Update…") {
                            perform { try await controller.installDriver() }
                        }
                    }
                    if controller.driverState != .notInstalled {
                        Button("Uninstall Virtual Microphone…", role: .destructive) { confirmUninstall = true }
                    }
                    if working { ProgressView().controlSize(.small) }
                }
                .disabled(working)
                if let error {
                    Text("\(error.title). \(error.advice)").font(.caption).foregroundStyle(.orange)
                }
            }

            if updates.isAvailable {
                Section("Updates") {
                    Button("Check for Updates…") { updates.checkForUpdates() }
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Link("Source code and help", destination: URL(string: "https://github.com/Showdown76py/Hush")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            devices = AudioDevices.inputDevices()
            controller.refreshDriverState()
        }
        .confirmationDialog("Remove the Hush microphone?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) { perform { try await controller.uninstallDriver() } }
        } message: {
            Text("Apps using “Hush Microphone” will lose their microphone. macOS will ask for your password.")
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await action() } catch { self.error = error as? HushError ?? .installFailed }
            working = false
        }
    }
}
