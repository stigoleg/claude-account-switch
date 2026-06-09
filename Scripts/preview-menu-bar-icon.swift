#!/usr/bin/env swift

// Renders the menu-bar icon at 4x scale to /tmp/menubar-icon-preview.png so
// the artwork can be verified without launching the app. Mirrors the drawing
// code in ClaudeProfileSwitcherApp.ProfileMenuBarIcon.

import AppKit
import Foundation

let canvas = NSSize(width: 18, height: 18)
let activeHex: String? = "#E07856"  // Claude orange; nil for template preview

func nsColor(fromHex hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

let tint: NSColor = activeHex.flatMap(nsColor(fromHex:)) ?? .black

let image = NSImage(size: canvas, flipped: false) { _ in
    tint.setFill()
    tint.setStroke()
    let filled = NSBezierPath(ovalIn: NSRect(x: 0, y: 7, width: 11, height: 11))
    filled.fill()
    let lineWidth: CGFloat = 1.6
    let outlineRect = NSRect(x: 7, y: 0, width: 11, height: 11)
        .insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let outline = NSBezierPath(ovalIn: outlineRect)
    outline.lineWidth = lineWidth
    outline.stroke()
    return true
}

// Render to a 4x bitmap for preview clarity.
let scale: CGFloat = 4
let bigSize = NSSize(width: canvas.width * scale, height: canvas.height * scale)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(bigSize.width),
    pixelsHigh: Int(bigSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(origin: .zero, size: bigSize))
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode png\n".utf8))
    exit(1)
}
let out = URL(fileURLWithPath: "/tmp/menubar-icon-preview.png")
try data.write(to: out)
print("wrote \(out.path) — open it to inspect")
