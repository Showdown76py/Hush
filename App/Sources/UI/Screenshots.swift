import SwiftUI

@MainActor
enum Screenshots {
    static func render(to directory: String) {
        let controller = EngineController()
        let updates = UpdateController()
        controller.applyPreview(status: .running, clients: 1, source: "MacBook Air Microphone", levels: (raw: 0.02, clean: 0.004))
        let windowBackground = Color(nsColor: .windowBackgroundColor)

        // real window shown then screencapture since ImageRenderer doesn't draw AppKit controls
        // and liquid glass is composited by the window server
        func save<V: View>(_ name: String, _ view: V) {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let host = NSHostingView(rootView: view
                    .environmentObject(controller)
                    .environmentObject(updates)
                    .background(windowBackground))
                let size = host.fittingSize
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
        controller.applyPreview(status: .running, clients: 1, source: "MacBook Air Microphone", levels: (raw: 0.02, clean: 0.004),
                                driverState: .updateAvailable)
        save("menu-driver-update", MenuContentView())
        controller.applyPreview(status: .running, clients: 1, source: "MacBook Air Microphone", levels: (raw: 0.02, clean: 0.004))
        for step in 0..<5 {
            save("onboarding-\(step + 1)", OnboardingView(initialStep: step))
        }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                for (name, look, badge) in [("active", MenuBarIcon.Look.active, NSColor?.none), ("standby", .standby, nil),
                                            ("off", .off, nil), ("update", .active, NSColor.systemOrange)] {
                    let icon = MenuBarIcon.image(look: look, badge: badge)
                    let scale: CGFloat = 4
                    let size = NSSize(width: icon.size.width * scale + 16, height: icon.size.height * scale + 16)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    (suffix == "dark" ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(origin: .zero, size: size).fill()
                    // macOS tints template images w/ the menu bar text color so do the same
                    let shown: NSImage
                    if icon.isTemplate {
                        shown = NSImage(size: icon.size, flipped: false) { r in
                            icon.draw(in: r)
                            (suffix == "dark" ? NSColor.white : NSColor.black).set()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                    } else { shown = icon }
                    shown.draw(in: NSRect(x: 8, y: 8, width: icon.size.width * scale, height: icon.size.height * scale))
                    NSGraphicsContext.restoreGraphicsState()
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("menubar-\(name)-\(suffix).png"))
                }
            }
        }
        save("discord", DiscordGuideView(showsDoneButton: false).padding(28).frame(width: 560))
        save("settings", SettingsView())
        exit(0)
    }
}

/// borderless window doesn't become active by default and macOS then desaturates the glass
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
