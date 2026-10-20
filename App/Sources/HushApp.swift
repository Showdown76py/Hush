import Sparkle
import SwiftUI

@main
struct HushApp: App {
    @StateObject private var controller = EngineController()
    private let updates = UpdateController()

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
        controller = key.isEmpty ? nil : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }
    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

/// Icône de la barre de menus ; ouvre l'onboarding au premier lancement.
struct MenuBarLabel: View {
    @EnvironmentObject private var controller: EngineController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: controller.status.menuBarSymbol)
            .task {
                if !controller.onboardingCompleted && !isRunningUnitTests {
                    openWindow(id: WindowID.onboarding)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .accessibilityLabel(Text("Hush"))
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
