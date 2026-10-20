import Foundation
import os

/// admin rights go through osascript's system dialog so the app never sees the password
enum DriverInstaller {
    private static let log = Logger(subsystem: "io.github.showdown76py.Hush", category: "installer")
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Hush.driver")

    static var bundledURL: URL? { Bundle.main.url(forResource: "Hush", withExtension: "driver") }
    static var scriptURL: URL? { Bundle.main.url(forResource: "driver-admin", withExtension: "sh") }

    static func version(at url: URL) -> String? {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String)
    }

    enum State: Equatable {
        case notInstalled
        case installed
        case updateAvailable
    }

    static var state: State {
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return .notInstalled }
        if let bundled = bundledURL.flatMap(version(at:)), let installed = version(at: installedURL),
           bundled.compare(installed, options: .numeric) == .orderedDescending {
            return .updateAvailable
        }
        return .installed
    }

    static func install() async throws {
        guard let source = bundledURL else { throw HushError.installFailed }
        try await runPrivileged(action: "install", argument: source.path)
        // coreaudiod restarts so wait for the device to show up
        for _ in 0..<40 {
            if AudioDevices.isHushDevicePresent { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        log.error("le périphérique n'est pas apparu après installation")
        throw HushError.installFailed
    }

    static func uninstall() async throws {
        try await runPrivileged(action: "uninstall", argument: nil)
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runPrivileged(action: String, argument: String?) async throws {
        guard let script = scriptURL else { throw HushError.installFailed }
        var command = "/bin/bash " + shellQuote(script.path) + " " + action
        if let argument { command += " " + shellQuote(argument) }
        let prompt = action == "install"
            ? String(localized: "Hush needs to install its virtual microphone. This is done once.")
            : String(localized: "Hush needs to remove its virtual microphone.")
        let source = "do shell script \(appleScriptQuote(command)) with prompt \(appleScriptQuote(prompt)) with administrator privileges"

        let (status, stderr) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Int32, String), Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            p.terminationHandler = { proc in
                let data = err.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
        guard status == 0 else {
            log.error("\(action, privacy: .public) a échoué (\(status)) : \(stderr, privacy: .public)")
            if stderr.contains("-128") { throw HushError.installCancelled }   // userCanceledErr
            throw action == "install" ? HushError.installFailed : HushError.uninstallFailed
        }
    }
}
