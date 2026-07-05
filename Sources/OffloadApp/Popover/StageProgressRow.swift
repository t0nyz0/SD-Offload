import SwiftUI

struct StageProgressRow: View {
    let label: String
    let fraction: Double
    let speedText: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            ProgressView(value: min(1, max(0, fraction)))
                .progressViewStyle(.linear)
                .tint(tint)
            Text("\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
            Text(speedText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
    }
}
