#!/usr/bin/env swift
//
// Draws the installer window background for the release DMG.
//
// CoreGraphics only, so the release box needs no extra tooling. Finder draws the real app and
// Applications icons on top of this at the positions release.sh sets; everything here is the
// frame around them — brand mark, drop-zone plates and the arrow between.
//
// Usage: make-dmg-background.swift <logo.png> <out.png> [version]

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write("usage: make-dmg-background.swift <logo.png> <out.png> [version]\n".data(using: .utf8)!)
    exit(2)
}
let logoPath = arguments[1]
let outputPath = arguments[2]
let version = arguments.count > 3 ? arguments[3] : ""

// Points. Kept in sync with the Finder window bounds in release.sh.
let width = 660
let height = 420
// 1x only. Finder ignores the DPI tag on a @2x background and simply refuses to draw it —
// verified by building the DMG both ways: the 2x image never painted, the 1x image did.
let scale = 1

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: width * scale,
        height: height * scale,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    FileHandle.standardError.write("could not create bitmap context\n".data(using: .utf8)!)
    exit(1)
}
context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
// Brand palette, taken from assets/logo.svg.
let backgroundTop = rgb(0x1f, 0x1f, 0x24)
let backgroundBottom = rgb(0x10, 0x10, 0x13)
let accent = rgb(0xff, 0x45, 0x3a)

// Background gradient.
if let gradient = CGGradient(colorsSpace: colorSpace,
                             colors: [backgroundTop, backgroundBottom] as CFArray,
                             locations: [0, 1]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: CGFloat(height)),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
}

// Soft accent sheen behind the wordmark.
if let sheen = CGGradient(colorsSpace: colorSpace,
                          colors: [rgb(0xff, 0x45, 0x3a, 0.16), rgb(0xff, 0x45, 0x3a, 0)] as CFArray,
                          locations: [0, 1]) {
    context.drawRadialGradient(sheen,
                               startCenter: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) - 40),
                               startRadius: 0,
                               endCenter: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) - 40),
                               endRadius: 260,
                               options: [])
}

let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsContext

// Brand mark.
if let logo = NSImage(contentsOfFile: logoPath) {
    let side: CGFloat = 54
    logo.draw(in: NSRect(x: 44, y: CGFloat(height) - side - 34, width: side, height: side),
              from: .zero, operation: .sourceOver, fraction: 1)
}

func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking
    ]
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
}

draw("Zerm", at: NSPoint(x: 110, y: CGFloat(height) - 74), size: 34, weight: .bold,
     color: .white, tracking: -0.5)
draw(version.isEmpty ? "Dictation that stays on your Mac" : "Version \(version)",
     at: NSPoint(x: 112, y: CGFloat(height) - 96), size: 12, weight: .medium,
     color: NSColor(white: 1, alpha: 0.55))

draw("Drag Zerm into your Applications folder",
     at: NSPoint(x: 44, y: 44), size: 12.5, weight: .regular,
     color: NSColor(white: 1, alpha: 0.5))

NSGraphicsContext.restoreGraphicsState()

// Drop-zone plates. Finder centres the icons on these; see release.sh for the positions.
func plate(centerX: CGFloat, centerY: CGFloat) {
    let size = CGSize(width: 168, height: 168)
    let rect = CGRect(x: centerX - size.width / 2, y: centerY - size.height / 2,
                      width: size.width, height: size.height)
    let path = CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil)
    context.addPath(path)
    context.setFillColor(rgb(0xff, 0xff, 0xff, 0.04))
    context.fillPath()
    context.addPath(path)
    context.setStrokeColor(rgb(0xff, 0xff, 0xff, 0.10))
    context.setLineWidth(1)
    context.strokePath()
}
// `iconCenterY` is the Finder position release.sh sets; flip it into CoreGraphics space, then
// lift the plate slightly so the icon sits optically centred above its filename label.
let iconCenterY: CGFloat = 218
let plateCenterY = CGFloat(height) - iconCenterY + 10
plate(centerX: 170, centerY: plateCenterY)
plate(centerX: 490, centerY: plateCenterY)

// Arrow between the plates.
context.setStrokeColor(accent)
context.setLineWidth(2.5)
context.setLineCap(.round)
context.move(to: CGPoint(x: 292, y: plateCenterY))
context.addLine(to: CGPoint(x: 362, y: plateCenterY))
context.strokePath()
context.setFillColor(accent)
context.move(to: CGPoint(x: 374, y: plateCenterY))
context.addLine(to: CGPoint(x: 358, y: plateCenterY + 9))
context.addLine(to: CGPoint(x: 358, y: plateCenterY - 9))
context.closePath()
context.fillPath()

guard let image = context.makeImage() else {
    FileHandle.standardError.write("could not render image\n".data(using: .utf8)!)
    exit(1)
}
let url = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write("could not create \(outputPath)\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("could not write \(outputPath)\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outputPath) (\(width)x\(height) @\(scale)x)")
