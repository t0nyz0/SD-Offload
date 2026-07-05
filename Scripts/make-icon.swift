#!/usr/bin/env swift
// Offload app icon generator.
//
// The mark: a machined graphite squircle holding an SD-card silhouette. The
// card is filled ~64% with the verification gradient (emerald base → amber
// leading edge), and an upward chevron is carved out of the fill in NEGATIVE
// space — "card in, data offloaded up to safe storage." The rising fill is the
// same motif used in the menu bar and the popover gauge.
//
// Run once, commit the PNG; build-app.sh turns it into AppIcon.icns.

import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a).cgColor
}
let rgb = CGColorSpaceCreateDeviceRGB()

// ---- Plate: graphite squircle (macOS grid inset 9.4%, radius 22.37%) --------
let inset = size * 0.094
let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let plateRadius = plate.width * 0.2237
let platePath = CGPath(roundedRect: plate, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.014), blur: size * 0.05,
              color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(platePath); ctx.setFillColor(color(0x16181D)); ctx.fillPath()
ctx.restoreGState()

// Plate gradient wash.
ctx.saveGState(); ctx.addPath(platePath); ctx.clip()
let plateGrad = CGGradient(colorsSpace: rgb, colors: [color(0x232730), color(0x0E0F13)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(plateGrad, start: CGPoint(x: plate.midX, y: plate.maxY),
                       end: CGPoint(x: plate.midX, y: plate.minY), options: [])
// Machined top-edge highlight (light catching the bevel).
ctx.setLineWidth(size * 0.004)
ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: size * 0.006, dy: size * 0.006),
                   cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil))
ctx.replacePathWithStrokedPath()
ctx.clip()
let edgeGrad = CGGradient(colorsSpace: rgb, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 0.5])!
ctx.drawLinearGradient(edgeGrad, start: CGPoint(x: plate.midX, y: plate.maxY),
                       end: CGPoint(x: plate.midX, y: plate.midY), options: [])
ctx.restoreGState()

// ---- SD-card silhouette -----------------------------------------------------
func sdCardPath(in rect: CGRect) -> CGPath {
    let r = rect.width * 0.11
    let bevel = rect.width * 0.26
    let p = CGMutablePath()
    // CG coords: origin bottom-left; bevel at the TOP-right.
    p.move(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - bevel, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bevel))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
    p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
    p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
    p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
    p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .pi, endAngle: .pi / 2, clockwise: true)
    p.closeSubpath()
    return p
}

let cardW = plate.width * 0.44
let cardH = cardW * 30 / 24
let cardRect = CGRect(x: plate.midX - cardW / 2, y: plate.midY - cardH / 2, width: cardW, height: cardH)
let cardPath = sdCardPath(in: cardRect)

// Card well (dark, faint inner surface).
ctx.saveGState(); ctx.addPath(cardPath); ctx.clip()
ctx.setFillColor(color(0x0B0C0F)); ctx.fill(cardRect)

// Rising verification fill (~72%), clipped to the card.
let fillFraction: CGFloat = 0.72
let fillTop = cardRect.minY + cardRect.height * fillFraction
let fillRect = CGRect(x: cardRect.minX, y: cardRect.minY, width: cardRect.width, height: cardRect.height * fillFraction)
ctx.saveGState(); ctx.clip(to: fillRect)
let fillGrad = CGGradient(colorsSpace: rgb, colors: [color(0x2BB673), color(0x34D399), color(0xF5A524), color(0xFF8A3D)] as CFArray,
                          locations: [0, 0.45, 0.85, 1])!
ctx.drawLinearGradient(fillGrad, start: CGPoint(x: cardRect.midX, y: cardRect.minY),
                       end: CGPoint(x: cardRect.midX, y: fillTop), options: [])
ctx.restoreGState()

// Leading-edge glow line.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: size * 0.02, color: color(0xFF8A3D, 0.9))
ctx.setFillColor(color(0xFFB36B))
ctx.fill(CGRect(x: cardRect.minX, y: fillTop - size * 0.004, width: cardRect.width, height: size * 0.008))
ctx.restoreGState()
ctx.restoreGState()   // end card clip

// ---- Negative-space upward chevron carved from the fill ---------------------
// A clean two-stroke chevron with round joins, punched out in the plate color.
// Rounded caps + mitre make it read as machined, not clip-art.
func chevronPath(apex: CGPoint, halfWidth: CGFloat, drop: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: apex.x - halfWidth, y: apex.y - drop))
    p.addLine(to: apex)
    p.addLine(to: CGPoint(x: apex.x + halfWidth, y: apex.y - drop))
    return p
}
let chevHalf = cardRect.width * 0.24
let chevApex = CGPoint(x: cardRect.midX, y: cardRect.midY + cardRect.height * 0.10)
let chev = chevronPath(apex: chevApex, halfWidth: chevHalf, drop: chevHalf * 0.78)
ctx.saveGState()
ctx.setLineWidth(cardRect.width * 0.115)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.0025), blur: size * 0.005, color: color(0x000000, 0.30))
ctx.addPath(chev); ctx.setStrokeColor(color(0x121419)); ctx.strokePath()
ctx.restoreGState()

// Card outline + contact pins.
ctx.saveGState()
ctx.addPath(cardPath); ctx.setStrokeColor(color(0xF2F4F8, 0.92)); ctx.setLineWidth(size * 0.013); ctx.strokePath()
ctx.setFillColor(color(0xF2F4F8, 0.8))
let padW = cardRect.width * 0.085, padH = cardRect.height * 0.075
for i in 0..<3 {
    let x = cardRect.minX + cardRect.width * (0.17 + Double(i) * 0.21)
    let pad = CGRect(x: x, y: cardRect.maxY - padH - cardRect.height * 0.05, width: padW, height: padH)
    ctx.addPath(CGPath(roundedRect: pad, cornerWidth: padW * 0.3, cornerHeight: padW * 0.3, transform: nil))
}
ctx.fillPath()
ctx.restoreGState()

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("Sources/OffloadApp/Resources/icon-1024.png")
try! png.write(to: out)
print("wrote \(out.path) (\(png.count) bytes)")
