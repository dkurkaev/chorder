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

/// Сетка тактов, разложенная по проведениям фразы.
///
/// Ровные ряды по четыре ломаются на первом же укороченном проведении: дальше одинаковые
/// места фразы перестают стоять друг под другом, и разметку становится невозможно читать
/// глазами. Поэтому строка здесь — это проведение фразы, даже если тактов в нём меньше.
struct BarsGridView: View {
    let bars: [Bar]
    let currentTime: Double
    /// Такты, с которых начинается новое проведение. Пусто — раскладываем поровну.
    var phraseStarts: [Int] = []

    private let maximumPerRow = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { bar in
                        cell(for: bar)
                    }
                    // Короткое проведение не растягиваем: такты должны сохранять ширину,
                    // иначе столбцы разъедутся и сравнивать строки будет не с чем.
                    if row.count < maximumPerRow {
                        ForEach(0..<(maximumPerRow - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    /// Аккорд, звучащий в такте в текущий момент.
    private func soundingChord(in bar: Bar) -> ChordLabel? {
        let count = bar.beatChords.count
        guard count > 0, bar.end > bar.start else { return bar.uniqueChords.first }
        let position = (currentTime - bar.start) / (bar.end - bar.start)
        let index = min(count - 1, max(0, Int(position * Double(count))))
        return bar.beatChords[index]
    }

    private var rows: [[Bar]] {
        let starts = phraseStarts.isEmpty
            ? Array_stride(from: 0, to: bars.count, by: maximumPerRow)
            : phraseStarts
        var result: [[Bar]] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : bars.count
            guard start < end, start < bars.count else { continue }
            // Длинное проведение всё равно приходится делить: в строку помещается
            // ограниченное число тактов.
            var position = start
            while position < min(end, bars.count) {
                let stop = min(position + maximumPerRow, end, bars.count)
                result.append(Array(bars[position..<stop]))
                position = stop
            }
        }
        return result
    }

    private func Array_stride(from: Int, to: Int, by: Int) -> [Int] {
        var result: [Int] = []
        var value = from
        while value < to {
            result.append(value)
            value += by
        }
        return result
    }

    private func cell(for bar: Bar) -> some View {
        let isActive = currentTime >= bar.start && currentTime < bar.end
        // Внутри такта аккорды сменяют друг друга, поэтому подсвечивается не весь такт
        // целиком, а тот аккорд, который звучит прямо сейчас.
        let sounding = isActive ? soundingChord(in: bar) : nil
        return VStack(alignment: .trailing, spacing: 2) {
            Text("\(bar.index + 1)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(isActive ? 1 : 0.6))
                .padding(.trailing, 4)

            VStack(spacing: 3) {
                ForEach(Array(bar.uniqueChords.enumerated()), id: \.offset) { _, chord in
                    ChordChip(label: chord, isActive: chord == sounding, size: 13, fillsWidth: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .id(bar.id)
    }
}
