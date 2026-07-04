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
            Text(speedText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }
}
