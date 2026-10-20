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

    var body: some View {
        Image(nsImage: MenuBarIcon.image(symbol: controller.status.menuBarSymbol,
                                         badge: controller.driverState == .updateAvailable))
            .task {
                if !controller.onboardingCompleted && !isHeadless {
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .accessibilityLabel(Text("Hush"))
    }
}

/// Icône de la barre de menus, avec une pastille orange quand une mise à jour du micro virtuel attend.
enum MenuBarIcon {
    static func image(symbol: String, badge: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Hush")?.withSymbolConfiguration(config) else {
            return NSImage()
        }
        guard badge else {
            base.isTemplate = true   // s'adapte seul au thème de la barre de menus
            return base
        }
        let size = NSSize(width: base.size.width + 3, height: base.size.height)
        // Dessin différé : la couleur du symbole suit l'apparence de la barre de menus au moment du rendu.
        let image = NSImage(size: size, flipped: false) { rect in
            let tinted = base.copy() as! NSImage
            tinted.lockFocus()
            NSColor.labelColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(origin: .zero, size: base.size))
            let d: CGFloat = 6
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension EngineController.Status {
    var menuBarSymbol: String {
        switch self {
        case .running: "mic.fill"
        case .starting: "mic"
        case .waiting: "mic"
        case .off: "mic.slash"
        case .problem: "mic.badge.xmark"
        }
    }
}
