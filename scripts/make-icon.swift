#!/usr/bin/env swift
// Builds Resources/AppIcon.icns from the artwork in Resources/AppIcon-source.png
// (clipped to the macOS icon squircle with a drop shadow). Run: scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
let source = NSImage(contentsOfFile: "Resources/AppIcon-source.png")!

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / canvas, y: size / canvas)

    // macOS icon grid: 824pt body with 100pt margin.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()
    ctx.saveGState()
    shape.addClip()
    source.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Run from the repository root.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! draw(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Resources/AppIcon.icns geschrieben" : "iconutil fehlgeschlagen")
