import SwiftUI

/// The classic SD-card silhouette: rounded rect with the top-right corner
/// replaced by a 45° bevel. Aspect ratio ≈ 24:30.
struct SDCardShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) * 0.10
        let bevel = rect.width * 0.24
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - bevel, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bevel))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .zero, endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The hero gauge: the card silhouette filling bottom-to-top with the
/// verification gradient. A soft glow rides the leading edge of the fill —
/// that amber line is "where the data is right now."
struct CardProgressView: View {
    var progress: Double            // 0…1
    var size: CGSize = CGSize(width: 88, height: 110)

    var body: some View {
        let p = min(1, max(0, progress))
        ZStack {
            // Empty well.
            SDCardShape()
                .fill(DS.Palette.ink.opacity(0.6))
            SDCardShape()
                .fill(DS.Palette.surfaceRaised.opacity(0.35))

            // Rising verification fill.
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(DS.verificationFill)
                        .frame(height: geo.size.height * p)
                    // Leading-edge glow.
                    Rectangle()
                        .fill(DS.Palette.motionHot)
                        .frame(height: 2)
                        .blur(radius: 3)
                        .opacity(p > 0.02 && p < 0.99 ? 0.9 : 0)
                        .offset(y: -geo.size.height * p + 1)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(SDCardShape())

            // Machined outline + a subtle top-edge highlight.
            SDCardShape()
                .stroke(DS.Palette.textPrimary.opacity(0.35), lineWidth: 1.5)
        }
        .frame(width: size.width, height: size.height)
        .animation(.linear(duration: 0.3), value: progress)
    }
}
