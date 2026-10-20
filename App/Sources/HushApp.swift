import Sparkle
import SwiftUI

@main
struct HushApp: App {
    @StateObject private var controller = EngineController()
    private let updates = UpdateController()

    init() {
        if let dir = screenshotDirectory {
            DispatchQueue.main.async { MainActor.assumeIsolated { Screenshots.render(to: dir) } }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(controller)
                .environmentObject(updates)
        } label: {
            MenuBarLabel()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)

        Window(Text("Welcome to Hush"), id: WindowID.onboarding) {
            OnboardingView()
                .environmentObject(controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(Text("Set up Discord"), id: WindowID.discord) {
            DiscordGuideView(showsDoneButton: false)
                .padding(28)
                .frame(width: 560)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(updates)
        }
    }
}

/// Vrai quand l'app sert seulement d'hôte aux tests unitaires.
let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
/// Mode "--render-screenshots <dossier>" : dessine les écrans en PNG puis quitte (README, revue du design).
let screenshotDirectory: String? = {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render-screenshots"), i + 1 < args.count else { return nil }
    return args[i + 1]
}()
/// Pas d'audio, pas de fenêtre automatique.
let isHeadless = isRunningUnitTests || screenshotDirectory != nil

enum WindowID {
    static let onboarding = "onboarding"
    static let discord = "discord"
}

/// Mises à jour automatiques (Sparkle). Désactivées tant que la clé publique EdDSA n'est pas
/// renseignée dans Info.plist (builds de développement).
final class UpdateController: ObservableObject {
    let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty || isHeadless
            ? nil : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }
    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

/// Icône de la barre de menus ; ouvre l'onboarding au premier lancement.
struct MenuBarLabel: View {
    @EnvironmentObject private var controller: EngineController
    @Environment(\.openWindow) private var openWindow

    private var badgeColor: NSColor? {
        if case .problem = controller.status { return .systemRed }
        return controller.driverState == .updateAvailable ? .systemOrange : nil
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.image(look: controller.status.menuBarLook, badge: badgeColor))
            .task {
                if !controller.onboardingCompleted && !isHeadless {
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .accessibilityLabel(Text("Hush"))
    }
}

/// Icône de la barre de menus tirée du logo de l'app : un micro entre deux ondes, « ( micro ) ».
/// Monochrome (image modèle) pour suivre le thème de la barre de menus ; une pastille de couleur signale un
/// problème (rouge) ou une mise à jour du micro virtuel (orange).
enum MenuBarIcon {
    enum Look { case active, standby, off }

    static func image(look: Look, badge: NSColor?) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            // Dessiné à l'affichage : `textColor` suit l'apparence de la barre de menus quand il y a une pastille.
            let ink = badge == nil ? NSColor.black : NSColor.textColor
            draw(look: look, ink: ink, in: size)
            if let badge {
                badge.setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width - 6, y: size.height - 6, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = badge == nil
        image.accessibilityDescription = "Hush"
        return image
    }

    private static func draw(look: Look, ink: NSColor, in size: NSSize) {
        let cx = size.width / 2
        // Micro : capsule, étrier et pied.
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: cx - 2.4, y: 6.6, width: 4.8, height: 8.2), xRadius: 2.4, yRadius: 2.4).fill()
        ink.setStroke()
        let stirrup = NSBezierPath()
        stirrup.appendArc(withCenter: NSPoint(x: cx, y: 9.4), radius: 4.4, startAngle: 200, endAngle: 340)
        stirrup.lineWidth = 1.4
        stirrup.lineCapStyle = .round
        stirrup.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: cx, y: 5.0)); stand.line(to: NSPoint(x: cx, y: 2.4))
        stand.move(to: NSPoint(x: cx - 2.6, y: 1.6)); stand.line(to: NSPoint(x: cx + 2.6, y: 1.6))
        stand.lineWidth = 1.4
        stand.lineCapStyle = .round
        stand.stroke()
        // Ondes « ( » et « ) », estompées en veille, absentes quand Hush est désactivé.
        if look != .off {
            ink.withAlphaComponent(look == .active ? 1 : 0.35).setStroke()
            for (start, end) in [(140.0, 220.0), (-40.0, 40.0)] {
                let wave = NSBezierPath()
                wave.appendArc(withCenter: NSPoint(x: cx, y: 8.6), radius: 8.6, startAngle: start, endAngle: end)
                wave.lineWidth = 1.4
                wave.lineCapStyle = .round
                wave.stroke()
            }
        } else {
            ink.setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: cx - 6, y: 14.5)); slash.line(to: NSPoint(x: cx + 6, y: 1.5))
            slash.lineWidth = 1.6
            slash.lineCapStyle = .round
            slash.stroke()
        }
    }
}

extension EngineController.Status {
    var menuBarLook: MenuBarIcon.Look {
        switch self {
        case .running: .active
        case .starting, .waiting, .problem: .standby
        case .off: .off
        }
    }
}
