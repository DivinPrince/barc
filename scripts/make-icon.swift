#!/usr/bin/env swift
// Usage: swift make-icon.swift --symbol drop.fill --from 8890FF --to 4038CC [--glyph 141233] [--shine] [--out AppIcon.iconset] [--icns AppIcon.icns]
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return fallback }
    return args[i + 1]
}
func color(_ hex: String) -> NSColor {
    var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    let v = UInt32(h, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

let symbolName = flag("symbol", "star.fill")
let top = color(flag("from", "8890FF"))
let bottom = color(flag("to", "4038CC"))
let glyph = color(flag("glyph", "141233"))
let scale = CGFloat(Double(flag("scale", "0.44")) ?? 0.44)
let shine = args.contains("--shine")
var outDir = flag("out", "AppIcon.iconset")
if !outDir.hasSuffix(".iconset") && !outDir.hasSuffix(".appiconset") { outDir += ".iconset" }
let icns = flag("icns", "")

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let canvas = rect.insetBy(dx: size * 0.08, dy: size * 0.08)
        let radius = canvas.width * 0.223
        let path = NSBezierPath(roundedRect: canvas, xRadius: radius, yRadius: radius)
        NSGradient(colors: [top, bottom])?.draw(in: path, angle: -80)

        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSRect(x: canvas.minX, y: canvas.midY, width: canvas.width, height: canvas.height / 2).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        let config = NSImage.SymbolConfiguration(pointSize: size * scale, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [glyph]))
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let s = symbol.size
            let r = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2 - size * 0.02, width: s.width, height: s.height)
            symbol.draw(in: r)
            if shine {
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.minX + s.width * 0.30, y: r.minY + s.height * 0.22, width: s.width * 0.13, height: s.height * 0.26)).fill()
            }
        }
        return true
    }
}

func png(_ image: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let master = drawIcon(size: 1024)
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                   ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try png(master, px).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name + ".png"))
}
print("Wrote \(outDir)")
if !icns.isEmpty {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", outDir, "-o", icns]
    try p.run(); p.waitUntilExit()
    print(p.terminationStatus == 0 ? "Wrote \(icns)" : "iconutil failed")
}
