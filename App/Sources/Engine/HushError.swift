import Foundation

/// Erreurs présentées à l'utilisateur : toujours un message humain, jamais de code Core Audio.
/// Le détail technique est seulement journalisé.
enum HushError: Error, Equatable {
    case microphonePermissionDenied
    case noInputDevice
    case virtualMicrophoneMissing
    case sharedMemoryUnavailable
    case voiceProcessingFailed
    case anotherInstanceRunning
    case installCancelled
    case installFailed
    case uninstallFailed

    var title: String {
        switch self {
        case .microphonePermissionDenied: String(localized: "Hush can’t use your microphone")
        case .noInputDevice: String(localized: "No microphone found")
        case .virtualMicrophoneMissing: String(localized: "The Hush microphone isn’t installed")
        case .sharedMemoryUnavailable: String(localized: "Hush can’t reach its virtual microphone")
        case .voiceProcessingFailed: String(localized: "Voice cleanup couldn’t start")
        case .anotherInstanceRunning: String(localized: "Another copy of Hush is running")
        case .installCancelled: String(localized: "Installation cancelled")
        case .installFailed: String(localized: "Installation didn’t work")
        case .uninstallFailed: String(localized: "Removal didn’t work")
        }
    }

    var advice: String {
        switch self {
        case .microphonePermissionDenied:
            String(localized: "Allow Hush in System Settings › Privacy & Security › Microphone. If it’s already on, turn it off and on again, then reopen Hush.")
        case .noInputDevice:
            String(localized: "Plug in a microphone or check that your Mac’s built-in microphone is enabled.")
        case .virtualMicrophoneMissing:
            String(localized: "Install it from the Hush menu. It only takes a few seconds.")
        case .sharedMemoryUnavailable:
            String(localized: "Restart your Mac. If it keeps happening, reinstall the virtual microphone from Settings.")
        case .voiceProcessingFailed:
            String(localized: "Another app may be using the microphone in an exclusive way. Hush will retry automatically.")
        case .anotherInstanceRunning:
            String(localized: "Quit the other copy (look for a second Hush icon in the menu bar). This one will take over automatically.")
        case .installCancelled:
            String(localized: "The virtual microphone is needed for other apps to hear the cleaned-up voice.")
        case .installFailed, .uninstallFailed:
            String(localized: "Make sure you entered an administrator password, then try again.")
        }
    }
}
