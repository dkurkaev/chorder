import SwiftUI

struct ChordChip: View {
    let label: ChordLabel
    var isActive: Bool = false
    var size: CGFloat = 15

    var body: some View {
        Text(label.isNone ? "—" : label.name)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(label.isNone ? Theme.textSecondary : Color.black.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.color(for: label))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white, lineWidth: isActive ? 2 : 0)
            )
            .scaleEffect(isActive ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)
    }
}

/// Сетка тактов: номер такта + аккорды по долям.
struct BarsGridView: View {
    let bars: [Bar]
    let currentTime: Double

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(bars) { bar in
                let isActive = currentTime >= bar.start && currentTime < bar.end
                VStack(alignment: .leading, spacing: 8) {
                    Text("Такт \(bar.index + 1)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        ForEach(Array(bar.uniqueChords.enumerated()), id: \.offset) { _, chord in
                            ChordChip(label: chord, size: 14)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isActive ? Theme.surfaceHigh : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.accent.opacity(isActive ? 0.8 : 0), lineWidth: 1.5)
                )
                .id(bar.id)
            }
        }
    }
}
