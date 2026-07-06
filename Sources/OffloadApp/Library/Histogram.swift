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
        for i in 1...254 { peak = max(peak, r[i], g[i], b[i]) }   // ignore clip spikes at 0/255
        return RGBHistogram(r: r, g: g, b: b, luma: luma, peak: peak)
    }
}

/// A compact RGB histogram, additive so channel overlaps read toward white — the
/// familiar photo-editor look. Loads off-main and redraws when the photo changes.
struct HistogramView: View {
    let url: URL
    @State private var hist: RGBHistogram?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HISTOGRAM")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.4))
            Canvas { context, size in
                guard let h = hist, size.width > 1, size.height > 1 else { return }
                var ctx = context
                ctx.blendMode = .plusLighter
                Self.fill(ctx, size, h.r, .red, h.peak)
                Self.fill(ctx, size, h.g, .green, h.peak)
                Self.fill(ctx, size, h.b, .blue, h.peak)
            }
            .frame(height: 84)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .redacted(reason: hist == nil ? .placeholder : [])
            if let a = hist?.analysis {
                HStack(spacing: 6) {
                    Circle().fill(a.tint).frame(width: 7, height: 7)
                    Text(a.headline).font(.system(size: 12, weight: .semibold))
                    Text(a.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .help("A rough read of the tone distribution — a guide, not a verdict.")
            }
        }
        .task(id: url) {
            hist = await Task.detached(priority: .utility) { HistogramComputer.compute(url: url) }.value
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
        ctx.fill(path, with: .color(color.opacity(0.55)))
    }
}
