import SwiftUI

struct DiscordGuideView: View {
    let showsDoneButton: Bool
    var done: () -> Void = {}

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Last step: choose Hush in Discord")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Open Discord › User Settings › Voice & Video, then set:")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VoiceSettingsSchematic()
            Text("Hush already removes echo and noise, so turn Discord’s own processing off to avoid cleaning your voice twice. In Zoom, Meet or OBS, pick “Hush Microphone” as the microphone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showsDoneButton {
                Button("Done", action: done)
                    .hushGlassButton(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// redrawn discord "Voice & Video" panel, not a screenshot
private struct VoiceSettingsSchematic: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("INPUT DEVICE").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.white.opacity(0.8))
                Text("Hush Microphone").foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.down").foregroundStyle(.white.opacity(0.6))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            .overlay(Callout(number: 1), alignment: .trailing)

            Divider().overlay(Color.white.opacity(0.15))
            SchematicToggle(label: "Echo Cancellation", number: 2)
            SchematicToggle(label: "Noise Suppression", value: "None", number: 3)
            SchematicToggle(label: "Automatic Gain Control", number: 4)
        }
        .padding(18)
        .frame(maxWidth: 440)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 0.19, green: 0.2, blue: 0.23)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Input device: Hush Microphone. Echo Cancellation off, Noise Suppression None, Automatic Gain Control off."))
    }
}

private struct SchematicToggle: View {
    let label: LocalizedStringKey
    var value: LocalizedStringKey?
    let number: Int

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.white)
            Spacer()
            if let value {
                Text(value).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.35)))
            } else {
                Capsule().fill(Color.gray.opacity(0.6)).frame(width: 38, height: 22)
                    .overlay(Circle().fill(.white).padding(3), alignment: .leading)
            }
            Callout(number: number).padding(.leading, 6)
        }
    }
}

private struct Callout: View {
    let number: Int
    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.yellow))
            .offset(x: 30)
    }
}
