#!/usr/bin/env swift
// Generates Sources/OffloadApp/Resources/icon-1024.png — the app icon:
// an SD-card silhouette on graphite, filled bottom-to-top with the
// amber→green gradient (the app's hero progress animation, frozen).
// Run once, commit the PNG; build-app.sh turns it into AppIcon.icns.

import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// macOS icon grid: content inset ~9.4%, corner radius ~22.37%.
let inset = size * 0.094
let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let plateRadius = plate.width * 0.2237

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.04,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
let platePath = CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)
ctx.addPath(platePath)
ctx.setFillColor(NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Plate gradient (graphite, subtle).
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let plateGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.23, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(plateGradient,
                       start: CGPoint(x: plate.midX, y: plate.maxY),
                       end: CGPoint(x: plate.midX, y: plate.minY), options: [])
ctx.restoreGState()

// SD-card silhouette path (rounded rect, beveled top-right corner).
func sdCardPath(in rect: CGRect) -> CGPath {
    let r = rect.width * 0.10
    let bevel = rect.width * 0.24
    let p = CGMutablePath()
    // CG coords: origin bottom-left; the bevel is at the TOP-right.
    p.move(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - bevel, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bevel))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
    p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
             startAngle: 0, endAngle: -.pi / 2, clockwise: true)
    p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
    p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
             startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
    p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
             startAngle: .pi, endAngle: .pi / 2, clockwise: true)
    p.closeSubpath()
    return p
}

let cardWidth = plate.width * 0.40
let cardHeight = cardWidth * 30 / 24
let cardRect = CGRect(x: plate.midX - cardWidth / 2, y: plate.midY - cardHeight / 2,
                      width: cardWidth, height: cardHeight)
let cardPath = sdCardPath(in: cardRect)

// Progress fill: bottom ~62%, amber→green gradient.
ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()
let fillRect = CGRect(x: cardRect.minX, y: cardRect.minY,
                      width: cardRect.width, height: cardRect.height * 0.62)
let fillGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(calibratedRed: 0.30, green: 0.72, blue: 0.38, alpha: 1).cgColor,   // green at the bottom (verified)
    NSColor(calibratedRed: 0.93, green: 0.62, blue: 0.18, alpha: 1).cgColor,   // amber at the fill line (in motion)
] as CFArray, locations: [0, 1])!
ctx.clip(to: fillRect)
ctx.drawLinearGradient(fillGradient,
                       start: CGPoint(x: cardRect.midX, y: fillRect.minY),
                       end: CGPoint(x: cardRect.midX, y: fillRect.maxY), options: [])
ctx.restoreGState()

// Card outline.
ctx.saveGState()
ctx.addPath(cardPath)
ctx.setStrokeColor(NSColor(calibratedWhite: 0.96, alpha: 0.92).cgColor)
ctx.setLineWidth(size * 0.014)
ctx.strokePath()
ctx.restoreGState()

// Contact pads: three small notches at the top of the card.
ctx.saveGState()
ctx.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 0.85).cgColor)
let padWidth = cardRect.width * 0.09
let padHeight = cardRect.height * 0.09
for i in 0..<3 {
    let x = cardRect.minX + cardRect.width * (0.16 + Double(i) * 0.20)
    let pad = CGRect(x: x, y: cardRect.maxY - padHeight - cardRect.height * 0.06,
                     width: padWidth, height: padHeight)
    ctx.addPath(CGPath(roundedRect: pad, cornerWidth: padWidth * 0.25, cornerHeight: padWidth * 0.25, transform: nil))
}
ctx.fillPath()
ctx.restoreGState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not render PNG")
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("Sources/OffloadApp/Resources/icon-1024.png")
try! png.write(to: out)
print("wrote \(out.path) (\(png.count) bytes)")
