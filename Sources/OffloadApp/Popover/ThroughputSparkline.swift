import SwiftUI
import Charts
import OffloadCore

/// Last-60-seconds throughput, two series: amber = card read, green = NAS write.
/// Appended at 1 Hz by the engine's speedSample events; deliberately unanimated.
struct ThroughputSparkline: View {
    let samples: [SpeedSample]

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                LineMark(x: .value("t", s.t), y: .value("read", s.sdReadBps / 1_000_000),
                         series: .value("series", "Card read"))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.t), y: .value("write", s.nasWriteBps / 1_000_000),
                         series: .value("series", "NAS write"))
                    .foregroundStyle(Theme.safe)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .overlay(alignment: .topTrailing) {
            if let last = samples.last {
                VStack(alignment: .trailing, spacing: 0) {
                    if last.sdReadBps > 0 {
                        Text(Fmt.speed(last.sdReadBps)).foregroundStyle(Theme.accent)
                    }
                    if last.nasWriteBps > 0 {
                        Text(Fmt.speed(last.nasWriteBps)).foregroundStyle(Theme.safe)
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .padding(2)
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }
}
