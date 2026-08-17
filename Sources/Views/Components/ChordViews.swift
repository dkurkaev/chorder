import SwiftUI

struct ChordChip: View {
    @Environment(\.chordPalette) private var palette

    let label: ChordLabel
    var isActive: Bool = false
    var size: CGFloat = 15
    var fillsWidth: Bool = false

    var body: some View {
        // По гайдлайнам Apple цвет — это акцент, а не заливка: название читается обычным
        // текстом на системном фоне, а цвет аккорда несёт точка рядом с ним. Выделение
        // текущего такта — тоже системное: подложка тона акцента, без теней и градиентов.
        let tint = palette.color(for: label)
        HStack(spacing: 6) {
            if !label.isNone {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            }
            Text(label.isNone ? "—" : label.name)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(label.isNone ? Color.secondary : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? AnyShapeStyle(tint.opacity(0.28)) : AnyShapeStyle(.quaternary))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(isActive ? 0.9 : 0), lineWidth: 1.5)
        }
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

/// Сетка тактов: аккорды и номер такта в углу.
struct BarsGridView: View {
    let bars: [Bar]
    let currentTime: Double

    // Четыре такта в ряд: подпись «Такт» не нужна, а номер уходит в угол,
    // поэтому ячейке хватает ширины одного-двух тэгов.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(bars) { bar in
                let isActive = currentTime >= bar.start && currentTime < bar.end
                VStack(alignment: .trailing, spacing: 2) {
                    // Номер нужен для сверки с разбором, поэтому он мелкий и не спорит
                    // с аккордом за внимание.
                    Text("\(bar.index + 1)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(isActive ? 1 : 0.6))
                        .padding(.trailing, 4)

                    VStack(spacing: 3) {
                        ForEach(Array(bar.uniqueChords.enumerated()), id: \.offset) { _, chord in
                            ChordChip(label: chord, isActive: isActive, size: 13, fillsWidth: true)
                        }
                    }
                }
                .id(bar.id)
            }
        }
    }
}
