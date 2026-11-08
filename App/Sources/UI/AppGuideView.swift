import SwiftUI

/// how to pick Hush Microphone in the usual apps. menus redrawn from each app, not screenshots
struct AppGuideView: View {
    var isOnboarding = false
    var done: () -> Void = {}
    @State private var app: GuideApp = .discord

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isOnboarding ? "Last step: choose Hush in your app" : "Use Hush in your apps")
                    .font(.title2.weight(.bold))
                Text("Any app that lets you choose a microphone works. Pick yours for the exact steps.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("App", selection: $app) {
                ForEach(GuideApp.allCases) { a in Text(a.name).tag(a) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 16) {
                GuideStep(number: 1, title: "Open the audio settings") {
                    Text(app.path).foregroundStyle(.secondary)
                }
                GuideStep(number: 2, title: "Set \(app.field) to “Hush Microphone”") {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").foregroundStyle(.secondary)
                        Text("Hush Microphone")
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 300)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator, lineWidth: 0.5))
                    .accessibilityElement(children: .combine)
                }
                GuideStep(number: 3, title: "Turn off the app’s own processing") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(app.turnOff, id: \.self) { item in
                            Label {
                                Text(item)
                            } icon: {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .animation(.snappy(duration: 0.2), value: app)

            Text("Hush already removes echo and noise. Leaving the app’s processing on cleans your voice twice and can make it sound thin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isOnboarding {
                Button("Done", action: done)
                    .hushGlassButton(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct GuideStep<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.hushBrand))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content
            }
            .padding(.top, 2)
        }
    }
}

enum GuideApp: String, CaseIterable, Identifiable {
    case discord, zoom, meet, teams, obs, other
    var id: String { rawValue }

    var name: String {
        switch self {
        case .discord: "Discord"
        case .zoom: "Zoom"
        case .meet: "Google Meet"
        case .teams: "Teams"
        case .obs: "OBS"
        case .other: String(localized: "Other")
        }
    }

    // names as each app shows them, in its own menus
    var path: String {
        switch self {
        case .discord: String(localized: "User Settings › Voice & Video")
        case .zoom: String(localized: "Settings › Audio")
        case .meet: String(localized: "More options › Settings › Audio")
        case .teams: String(localized: "Settings › Devices")
        case .obs: String(localized: "Settings › Audio")
        case .other: String(localized: "The app’s audio or microphone settings")
        }
    }

    var field: String {
        switch self {
        case .discord: String(localized: "Input Device")
        case .obs: String(localized: "Mic/Auxiliary Audio")
        // own key: the menu's "Microphone" is shortened to "Micro" in french, apps keep "Microphone"
        case .zoom, .meet, .teams, .other: String(localized: "Microphone setting")
        }
    }

    var turnOff: [String] {
        switch self {
        case .discord: [String(localized: "Echo Cancellation: off"), String(localized: "Noise Suppression: None"),
                        String(localized: "Automatic Gain Control: off")]
        case .zoom: [String(localized: "Background noise suppression: Low"),
                     String(localized: "Automatically adjust microphone volume: off")]
        case .meet: [String(localized: "Noise cancellation: off")]
        case .teams: [String(localized: "Noise suppression: Off")]
        case .obs: [String(localized: "No Noise Suppression filter on this source")]
        case .other: [String(localized: "Echo cancellation and noise suppression: off")]
        }
    }
}
