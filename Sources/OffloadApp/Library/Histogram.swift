import SwiftUI
import ImageIO

/// Per-channel tone distribution (256 bins each), for the viewer's histogram.
struct RGBHistogram: Sendable {
    var r: [Int]
    var g: [Int]
    var b: [Int]
    var luma: [Int]        // Rec.709 luminance, for the exposure read
    /// Scaling reference — the tallest bin ignoring the pure-black/white spikes,
    /// so clipped shadows/highlights don't flatten the rest of the curve.
    var peak: Int
    var lumaPeak: Int      // same, for the luminance overlay

    var analysis: ExposureAnalysis { ExposureAnalysis(luma: luma) }
}

/// A rough, honest read of the tone distribution — a guide, not a verdict.
struct ExposureAnalysis: Sendable {
    enum Kind: Sendable { case balanced, dark, bright, flat }
    let kind: Kind
    let meanPct: Int
    let shadowClipPct: Double
    let highlightClipPct: Double

    init(luma: [Int]) {
        let total = max(1, luma.reduce(0, +))
        var sum = 0.0
        for i in 0..<256 { sum += Double(i) * Double(luma[i]) }
        let mean = sum / Double(total) / 255.0                 // 0…1
        meanPct = Int((mean * 100).rounded())
        shadowClipPct = Double(luma[0]) / Double(total) * 100
        highlightClipPct = Double(luma[255]) / Double(total) * 100
        func percentile(_ q: Double) -> Int {
            let target = Double(total) * q
            var cum = 0
            for i in 0..<256 { cum += luma[i]; if Double(cum) >= target { return i } }
            return 255
        }
        let spread = Double(percentile(0.95) - percentile(0.05)) / 255.0
        if mean < 0.26 { kind = .dark }
        else if mean > 0.76 { kind = .bright }
        else if spread < 0.20 { kind = .flat }
        else { kind = .balanced }
    }

    var headline: String {
        switch kind {
        case .balanced: "Well exposed"
        case .dark: "Underexposed"
        case .bright: "Overexposed"
        case .flat: "Low contrast"
        }
    }
    var detail: String {
        var parts = ["avg \(meanPct)%"]
        if highlightClipPct >= 1 { parts.append("\(Int(highlightClipPct.rounded()))% highlights clipped") }
        if shadowClipPct >= 2 { parts.append("\(Int(shadowClipPct.rounded()))% shadows crushed") }
        if parts.count == 1 && kind == .balanced { parts.append("clean") }
        return parts.joined(separator: " · ")
    }
    var tint: Color {
        let clipping = highlightClipPct >= 1 || shadowClipPct >= 2
        switch kind {
        case .balanced: return clipping ? .orange : DS.safe
        case .dark, .bright: return .orange
        case .flat: return .yellow
        }
    }
}

enum HistogramComputer {
    /// Compute a histogram from a small decode of the image. Uses the embedded
    /// preview when present (cheap over SMB) — plenty for a tone distribution.
    static func compute(url: URL, maxPixel: Int = 320) -> RGBHistogram? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }

        let bytesPerRow = w * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        // Let CGContext own the buffer (valid while ctx lives); read it via ctx.data.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = base.bindMemory(to: UInt8.self, capacity: bytesPerRow * h)

        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)
        var luma = [Int](repeating: 0, count: 256)
        let pixelCount = w * h
        let step = max(1, pixelCount / 60_000)   // sample to bound work; plenty for a curve
        var p = 0
        while p < pixelCount {
            let o = p * 4
            let R = Int(data[o]), G = Int(data[o + 1]), B = Int(data[o + 2])
            r[R] += 1; g[G] += 1; b[B] += 1
            luma[min(255, (R * 54 + G * 183 + B * 19) >> 8)] += 1   // ≈ Rec.709 (0.2126/0.7152/0.0722)
            p += step
        }
        var peak = 1
        var lumaPeak = 1
        for i in 1...254 { peak = max(peak, r[i], g[i], b[i]); lumaPeak = max(lumaPeak, luma[i]) }   // ignore clip spikes at 0/255
        return RGBHistogram(r: r, g: g, b: b, luma: luma, peak: peak, lumaPeak: lumaPeak)
    }
}

/// A compact histogram: additive RGB channels (overlaps read toward white, the
/// familiar photo-editor look), a luminance outline for overall tone, tone-zone
/// gridlines, a mean-tone marker, and bright edge warnings when highlights or
/// shadows clip. Loads off-main and redraws when the photo changes.
struct HistogramView: View {
    let url: URL
    @State private var hist: RGBHistogram?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("HISTOGRAM")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.4))
            Canvas { context, size in
                guard let h = hist, size.width > 1, size.height > 1 else { return }
                Self.drawGrid(context, size)
                var add = context
                add.blendMode = .plusLighter
                Self.fill(add, size, h.r, .red, h.peak)
                Self.fill(add, size, h.g, .green, h.peak)
                Self.fill(add, size, h.b, .blue, h.peak)
                Self.strokeLuma(context, size, h.luma, h.lumaPeak)
                Self.drawMeanMarker(context, size, h.analysis.meanPct)
                Self.drawClipping(context, size, h.analysis)
            }
            .frame(height: 92)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .redacted(reason: hist == nil ? .placeholder : [])
            if let a = hist?.analysis { readout(a) }
        }
        .task(id: url) {
            hist = await Task.detached(priority: .utility) { HistogramComputer.compute(url: url) }.value
        }
    }

    @ViewBuilder private func readout(_ a: ExposureAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(a.tint).frame(width: 7, height: 7)
                Text(a.headline).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text("avg \(a.meanPct)%").font(.system(size: 10.5))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 12) {
                clipStat("sun.max.fill", "Highlights", a.highlightClipPct, warn: a.highlightClipPct >= 1, color: .orange)
                clipStat("moon.fill", "Shadows", a.shadowClipPct, warn: a.shadowClipPct >= 2, color: .cyan)
                Spacer(minLength: 0)
            }
        }
        .help("Tone distribution across the frame. A spike at the far right/left means clipped highlights/shadows — detail lost there.")
    }

    private func clipStat(_ symbol: String, _ label: String, _ pct: Double, warn: Bool, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8))
            Text("\(label) \(Int(pct.rounded()))%").font(.system(size: 10)).monospacedDigit()
        }
        .foregroundStyle(warn ? color : .white.opacity(0.32))
    }

    // MARK: - Canvas layers

    /// Faint dividers at the quarter tones — blacks | shadows | mids | highlights | whites.
    private static func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        for f in [0.25, 0.5, 0.75] {
            var line = Path()
            line.move(to: CGPoint(x: f * size.width, y: 0))
            line.addLine(to: CGPoint(x: f * size.width, y: size.height))
            ctx.stroke(line, with: .color(.white.opacity(0.05)), lineWidth: 1)
        }
    }

    private static func fill(_ ctx: GraphicsContext, _ size: CGSize, _ bins: [Int], _ color: Color, _ peak: Int) {
        let n = bins.count
        guard n > 1, peak > 0 else { return }
        let stepX = size.width / CGFloat(n - 1)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, v) in bins.enumerated() {
            let frac = min(CGFloat(v) / CGFloat(peak), 1)
            path.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: size.height - frac * size.height))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .color(color.opacity(0.5)))
    }

    /// A thin luminance outline over the RGB fills — the overall tonal curve.
    private static func strokeLuma(_ ctx: GraphicsContext, _ size: CGSize, _ bins: [Int], _ peak: Int) {
        let n = bins.count
        guard n > 1, peak > 0 else { return }
        let stepX = size.width / CGFloat(n - 1)
        var path = Path()
        for (i, v) in bins.enumerated() {
            let frac = min(CGFloat(v) / CGFloat(peak), 1)
            let pt = CGPoint(x: CGFloat(i) * stepX, y: size.height - frac * size.height)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        ctx.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 1)
    }

    /// A dashed vertical line at the mean tone — the frame's centre of exposure.
    private static func drawMeanMarker(_ ctx: GraphicsContext, _ size: CGSize, _ meanPct: Int) {
        let x = CGFloat(meanPct) / 100 * size.width
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(line, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
    }

    /// Bright warning bars at the very edges, scaled to how much is clipped, so blown
    /// highlights and crushed shadows are obvious at a glance.
    private static func drawClipping(_ ctx: GraphicsContext, _ size: CGSize, _ a: ExposureAnalysis) {
        func bar(right: Bool, pct: Double, color: Color) {
            guard pct >= 0.5 else { return }
            let intensity = min(1, pct / 12)
            let w = 2 + 4 * intensity
            let rect = Path(CGRect(x: right ? size.width - w : 0, y: 0, width: w, height: size.height))
            ctx.fill(rect, with: .color(color.opacity(0.4 + 0.45 * intensity)))
        }
        bar(right: true, pct: a.highlightClipPct, color: .orange)
        bar(right: false, pct: a.shadowClipPct, color: .cyan)
    }
}
