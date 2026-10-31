#!/usr/bin/env swift
// Draws the Hearth artwork into Resources/AppIcon-source.png (1024×1024, full bleed).
// scripts/make-icon.swift then clips it to the macOS squircle and builds AppIcon.icns.
// Run from the repo root: scripts/make-icon-source.swift && scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radial(_ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// Background: warm charcoal.
ctx.addRect(CGRect(x: 0, y: 0, width: size, height: size)); ctx.clip()
linear([rgb(0x2B1E19), rgb(0x120D0B)], from: CGPoint(x: 0, y: size), to: CGPoint(x: 0, y: 0))

// Hearth opening: a round arch with a stone rim.
func arch(inset: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let left = 212 + inset, right = size - 212 - inset, bottom: CGFloat = 196 + inset * 0.4
    let r = (right - left) / 2, springLine: CGFloat = 560
    p.move(to: CGPoint(x: left, y: bottom))
    p.addLine(to: CGPoint(x: left, y: springLine))
    p.addArc(center: CGPoint(x: size / 2, y: springLine), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    p.addLine(to: CGPoint(x: right, y: bottom))
    p.closeSubpath()
    return p
}
ctx.saveGState(); ctx.addPath(arch(inset: -34)); ctx.clip()
linear([rgb(0x5A4136), rgb(0x3A2A23)], from: CGPoint(x: 0, y: 900), to: CGPoint(x: 0, y: 160))
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(arch(inset: 0)); ctx.clip()
linear([rgb(0x0B0706), rgb(0x1C110C)], from: CGPoint(x: 0, y: 860), to: CGPoint(x: 0, y: 196))
radial([rgb(0xFF8A2A, 0.55), rgb(0xFF8A2A, 0)], center: CGPoint(x: size / 2, y: 250), radius: 330)
ctx.restoreGState()

// Hearth floor.
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: CGRect(x: 150, y: 150, width: size - 300, height: 62), cornerWidth: 18, cornerHeight: 18, transform: nil))
ctx.clip()
linear([rgb(0x6B4E40), rgb(0x47332A)], from: CGPoint(x: 0, y: 212), to: CGPoint(x: 0, y: 150))
ctx.restoreGState()

// Flames: an outer and an inner teardrop.
func flame(cx: CGFloat, base: CGFloat, width w: CGFloat, height h: CGFloat, lean: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let tip = CGPoint(x: cx + lean, y: base + h)
    p.move(to: tip)
    p.addCurve(to: CGPoint(x: cx + w / 2, y: base + h * 0.28),
               control1: CGPoint(x: cx + lean * 0.4 + w * 0.08, y: base + h * 0.78),
               control2: CGPoint(x: cx + w * 0.62, y: base + h * 0.52))
    p.addCurve(to: CGPoint(x: cx, y: base),
               control1: CGPoint(x: cx + w * 0.42, y: base + h * 0.08),
               control2: CGPoint(x: cx + w * 0.22, y: base))
    p.addCurve(to: CGPoint(x: cx - w / 2, y: base + h * 0.28),
               control1: CGPoint(x: cx - w * 0.22, y: base),
               control2: CGPoint(x: cx - w * 0.42, y: base + h * 0.08))
    p.addCurve(to: tip,
               control1: CGPoint(x: cx - w * 0.62, y: base + h * 0.55),
               control2: CGPoint(x: cx - w * 0.05 + lean * 0.5, y: base + h * 0.8))
    p.closeSubpath()
    return p
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xFF7A1A, 0.8))
ctx.addPath(flame(cx: size / 2, base: 222, width: 330, height: 470, lean: 26)); ctx.clip()
linear([rgb(0xFFC23D), rgb(0xFF7A1A), rgb(0xE5401C)], from: CGPoint(x: 0, y: 222), to: CGPoint(x: 0, y: 692))
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(flame(cx: size / 2 + 8, base: 228, width: 170, height: 270, lean: -12)); ctx.clip()
linear([rgb(0xFFF6D8), rgb(0xFFD25A)], from: CGPoint(x: 0, y: 228), to: CGPoint(x: 0, y: 498))
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-source.png"))
print("Wrote Resources/AppIcon-source.png")
