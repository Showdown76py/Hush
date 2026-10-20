#!/usr/bin/env swift
// Génère l'icône de Hush (1024 px) puis toutes les tailles de l'AppIcon.
// Usage : swift scripts/make-icon.swift <dossier AppIcon.appiconset>
// Concept : un micro blanc au centre ; de part et d'autre, des ondes sonores qui se dissolvent en
// points — la musique qui disparaît.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset"
let S: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Forme de base macOS : carré arrondi de 824 px centré (grille d'icône Apple), ombre portée.
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(color(0x1E1B4B)); ctx.fillPath()
    ctx.restoreGState()

    // Dégradé nuit : indigo profond en bas, violet lumineux en haut.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x17153B), color(0x3B2F8F), color(0x7A5CE0)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: S / 2, y: inset), end: CGPoint(x: S / 2, y: S - inset), options: [])
    // Halo doux derrière le micro.
    let halo = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xB9A8FF, 0.45), color(0xB9A8FF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: CGPoint(x: S / 2, y: S / 2 + 20), startRadius: 0,
                           endCenter: CGPoint(x: S / 2, y: S / 2 + 20), endRadius: 330, options: [])
    ctx.restoreGState()

    // Ondes qui se dissolvent : arcs pleins près du micro, puis pointillés de plus en plus fins.
    let center = CGPoint(x: S / 2, y: S / 2 + 40)
    for side in [-1.0, 1.0] {
        for i in 0..<3 {
            let r = CGFloat(185 + i * 72)
            let alpha = 0.85 - Double(i) * 0.25
            let start = side < 0 ? CGFloat.pi * 0.78 : -CGFloat.pi * 0.22
            let end = side < 0 ? CGFloat.pi * 1.22 : CGFloat.pi * 0.22
            if i == 0 {
                ctx.setStrokeColor(color(0xE9E4FF, alpha))
                ctx.setLineWidth(26); ctx.setLineCap(.round)
                ctx.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: false)
                ctx.strokePath()
            } else {
                let dots = 7 - i
                for d in 0..<dots {
                    let t = CGFloat(d) / CGFloat(dots - 1)
                    let a = start + (end - start) * t
                    let size: CGFloat = i == 1 ? 22 : 15
                    let p = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
                    ctx.setFillColor(color(0xE9E4FF, alpha * (1 - 0.35 * abs(t - 0.5) * 2)))
                    ctx.fillEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
                }
            }
        }
    }

    // Micro : capsule + étrier + pied.
    let capsule = CGRect(x: S / 2 - 78, y: center.y - 70, width: 156, height: 270)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0x0B0A24, 0.5))
    ctx.addPath(CGPath(roundedRect: capsule, cornerWidth: 78, cornerHeight: 78, transform: nil))
    let micGrad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xDCD6FF), color(0xFFFFFF)] as CFArray,
                             locations: [0, 1])!
    ctx.clip()
    ctx.drawLinearGradient(micGrad, start: CGPoint(x: 0, y: capsule.minY), end: CGPoint(x: 0, y: capsule.maxY), options: [])
    ctx.restoreGState()
    // Grille du micro : trois fentes discrètes.
    ctx.setStrokeColor(color(0x3B2F8F, 0.18)); ctx.setLineWidth(10); ctx.setLineCap(.round)
    for k in 0..<3 {
        let y = capsule.maxY - 70 - CGFloat(k) * 42
        ctx.move(to: CGPoint(x: capsule.minX + 42, y: y)); ctx.addLine(to: CGPoint(x: capsule.maxX - 42, y: y))
    }
    ctx.strokePath()
    ctx.setStrokeColor(color(0xFFFFFF)); ctx.setLineWidth(26); ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: S / 2, y: capsule.minY + 95), radius: 128, startAngle: .pi * 1.0, endAngle: .pi * 2.0, clockwise: false)
    ctx.strokePath()
    ctx.move(to: CGPoint(x: S / 2, y: capsule.minY - 33)); ctx.addLine(to: CGPoint(x: S / 2, y: capsule.minY - 100))
    ctx.move(to: CGPoint(x: S / 2 - 70, y: capsule.minY - 100)); ctx.addLine(to: CGPoint(x: S / 2 + 70, y: capsule.minY - 100))
    ctx.strokePath()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: S, height: S)).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let image = render()
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        writePNG(image, size: base * scale, to: "\(outDir)/\(name)")
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
print("icône écrite dans \(outDir)")
