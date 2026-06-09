#!/usr/bin/env swift

// Generates AppBundle/AppIcon.png (1024×1024) via CoreGraphics.
//
// Design: rounded square with a vertical orange gradient (Claude orange at
// the top to a darker shade at the bottom). Two overlapping white circles
// represent the two profiles being swapped. The corner radius matches the
// macOS app-icon mask (~22% of side).
//
// Deterministic — running twice produces a byte-identical PNG given the same
// inputs, which we rely on to avoid noisy diffs.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let cornerRadius: CGFloat = size * 0.22

// Claude orange (matches Profile.defaultColors[0]) at the top, a slightly
// darker variant at the bottom for depth.
let topColor = CGColor(red: 0xE0 / 255.0, green: 0x78 / 255.0, blue: 0x56 / 255.0, alpha: 1.0)
let bottomColor = CGColor(red: 0xC9 / 255.0, green: 0x5E / 255.0, blue: 0x40 / 255.0, alpha: 1.0)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("error: could not allocate CGContext\n".utf8))
    exit(1)
}

// Flip the coordinate system so y increases downward — matches the way I
// reason about positions in the design.
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)

// Rounded-square clip.
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let roundedPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
context.addPath(roundedPath)
context.clip()

// Background gradient.
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [topColor, bottomColor] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: size / 2, y: 0),
    end: CGPoint(x: size / 2, y: size),
    options: []
)

// Two overlapping circles in white (~75% opacity) — the "two profiles" motif.
// Upper-left circle is slightly larger to suggest the active profile.
let centerX = size / 2
let centerY = size / 2
let circleRadius = size * 0.21
let offset = circleRadius * 0.75
let circleStrokeWidth = size * 0.018

// Soft inner shadow for depth.
context.setShadow(
    offset: CGSize(width: 0, height: 6),
    blur: 12,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25)
)

// Upper-left circle (filled white, mostly opaque).
context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.95)
context.fillEllipse(in: CGRect(
    x: centerX - offset - circleRadius,
    y: centerY - offset - circleRadius,
    width: circleRadius * 2,
    height: circleRadius * 2
))

// Lower-right circle (outlined to suggest a "switch target").
context.setShadow(offset: .zero, blur: 0, color: nil)
context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.95)
context.setLineWidth(circleStrokeWidth)
context.strokeEllipse(in: CGRect(
    x: centerX + offset - circleRadius,
    y: centerY + offset - circleRadius,
    width: circleRadius * 2,
    height: circleRadius * 2
))

// Subtle "swap" mark connecting the two — a small white circle exactly at
// the meeting point so the swap action reads even at small sizes.
let pivotRadius = size * 0.025
context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.85)
context.fillEllipse(in: CGRect(
    x: centerX - pivotRadius,
    y: centerY - pivotRadius,
    width: pivotRadius * 2,
    height: pivotRadius * 2
))

// Make the image and write it as PNG.
guard let cgImage = context.makeImage() else {
    FileHandle.standardError.write(Data("error: could not make image\n".utf8))
    exit(1)
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputURL = repoRoot.appendingPathComponent("AppBundle/AppIcon.png")

try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    FileHandle.standardError.write(Data("error: could not create image destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, cgImage, nil)
if !CGImageDestinationFinalize(dest) {
    FileHandle.standardError.write(Data("error: could not finalize PNG\n".utf8))
    exit(1)
}

print("wrote \(outputURL.path)")
