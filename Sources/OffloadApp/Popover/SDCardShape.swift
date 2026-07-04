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

/// The hero: the card silhouette filling bottom-to-top with progress.
struct CardProgressView: View {
    var progress: Double            // 0…1
    var size: CGSize = CGSize(width: 84, height: 104)

    var body: some View {
        ZStack {
            SDCardShape()
                .fill(.quaternary.opacity(0.4))
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.accentGradient)
                    .frame(height: geo.size.height * min(1, max(0, progress)))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(SDCardShape())
            SDCardShape()
                .stroke(.secondary.opacity(0.5), lineWidth: 1.5)
        }
        .frame(width: size.width, height: size.height)
        .animation(.linear(duration: 0.3), value: progress)
    }
}
