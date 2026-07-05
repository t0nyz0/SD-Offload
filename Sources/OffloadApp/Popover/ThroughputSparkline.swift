import SwiftUI
import OffloadCore

/// Last ~2 minutes of throughput as two flowing ribbons — amber = card read,
/// green = NAS write. Canvas-drawn for precise control: a fixed rolling time
/// window so the trace always spans the full width and scrolls right-to-left
/// (a consistent "tail"), an area fill that fades downward, and an emphasized
/// dot at the live endpoint. Deliberately unanimated — the data is the motion.
struct ThroughputSparkline: View {
    let samples: [SpeedSample]
    var window: TimeInterval = 120

    var body: some View {
        Canvas { ctx, size in
            guard let last = samples.last else { return }
            let maxT = last.t
            let minT = maxT - window
            let visible = samples.filter { $0.t >= minT }
            guard visible.count >= 2 else { return }

            // Shared y-scale across both series; 1 MB/s floor keeps idle flat.
            var peak = 1_000_000.0
            for s in visible { peak = max(peak, s.sdReadBps, s.nasWriteBps) }
            peak *= 1.15   // headroom so the peak isn't glued to the top edge

            let span = max(maxT - minT, 0.001)
            func x(_ t: TimeInterval) -> CGFloat { CGFloat((t - minT) / span) * size.width }
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(v / peak) * (size.height - 6) - 3 }

            func drawSeries(_ value: (SpeedSample) -> Double, color: Color) {
                var line = Path()
                var area = Path()
                for (i, s) in visible.enumerated() {
                    let p = CGPoint(x: x(s.t), y: y(value(s)))
                    if i == 0 {
                        line.move(to: p)
                        area.move(to: CGPoint(x: p.x, y: size.height))
                        area.addLine(to: p)
                    } else {
                        line.addLine(to: p)
                        area.addLine(to: p)
                    }
                }
                let endX = x(visible[visible.count - 1].t)
                area.addLine(to: CGPoint(x: endX, y: size.height))
                area.closeSubpath()

                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.30), color.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))

                let end = CGPoint(x: endX, y: y(value(visible[visible.count - 1])))
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                         with: .color(color))
            }

            drawSeries({ $0.sdReadBps }, color: DS.motion)
            drawSeries({ $0.nasWriteBps }, color: DS.safe)
        }
        .overlay(alignment: .topTrailing) {
            if let last = samples.last {
                VStack(alignment: .trailing, spacing: 0) {
                    if last.sdReadBps > 0 { Text(Fmt.speed(last.sdReadBps)).foregroundStyle(DS.motion) }
                    if last.nasWriteBps > 0 { Text(Fmt.speed(last.nasWriteBps)).foregroundStyle(DS.safe) }
                }
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .padding(4)
            }
        }
        .background(DS.Palette.surfaceRaised.opacity(0.25), in: RoundedRectangle(cornerRadius: DS.Radius.s))
    }
}
