import SwiftUI

/// Rend les principaux écrans en PNG (clair + sombre) avec des données de démonstration.
@MainActor
enum Screenshots {
    static func render(to directory: String) {
        let controller = EngineController()
        let updates = UpdateController()
        controller.applyPreview(status: .running, clients: 1, source: "MacBook Air Microphone", levels: (raw: 0.02, clean: 0.004))
        let windowBackground = Color(nsColor: .windowBackgroundColor)

        // Rendu dans une vraie fenêtre hors écran : contrairement à ImageRenderer, les contrôles
        // AppKit (boutons, menus, segments) sont dessinés.
        func save<V: View>(_ name: String, _ view: V) {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let host = NSHostingView(rootView: view
                    .environmentObject(controller)
                    .environmentObject(updates)
                    .background(windowBackground))
                let size = host.fittingSize
                // Fenêtre réellement affichée : Liquid Glass est composé par le serveur de fenêtres,
                // seule une vraie capture d'écran le restitue.
                let window = KeyableWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.level = .floating
                NSApp.setActivationPolicy(.accessory)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.contentView = host
                window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                let path = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png").path
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
                try? p.run()
                p.waitUntilExit()
                window.orderOut(nil)
            }
        }

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        save("menu", MenuContentView())
        for step in 0..<5 {
            save("onboarding-\(step + 1)", OnboardingView(initialStep: step))
        }
        save("discord", DiscordGuideView(showsDoneButton: false).padding(28).frame(width: 560))
        save("settings", SettingsView())
        exit(0)
    }
}

/// Fenêtre sans bordure capable de devenir active (sinon macOS désature le verre).
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
