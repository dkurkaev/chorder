import SwiftUI

/// Живой спектр: столбики по логарифмической шкале частот.
struct SpectrumView: View {
    let levels: [Float]
    var isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, levels.count)
            let spacing: CGFloat = 3
            let width = max(2, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let level = CGFloat(max(0.015, min(1, levels[index])))
                    RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accentWarm],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .opacity(isActive ? 0.55 + 0.45 * level : 0.22)
                        .frame(width: width, height: max(3, geometry.size.height * level))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.linear(duration: 0.06), value: levels)
        }
    }
}

/// Двенадцать классов высоты: видно, какие ноты сейчас звучат и из чего собран аккорд.
struct ChromaStripView: View {
    let values: [Float]
    let chord: ChordLabel

    private var chordTones: Set<Int> {
        guard let root = chord.root, let quality = chord.quality else { return [] }
        return Set(quality.intervals.map { (root + $0) % 12 })
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<12, id: \.self) { pitchClass in
                let level = CGFloat(max(0, min(1, values.indices.contains(pitchClass) ? values[pitchClass] : 0)))
                let isChordTone = chordTones.contains(pitchClass)
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isChordTone ? Theme.accentWarm : Theme.accent)
                        .opacity(0.25 + 0.75 * level)
                        .frame(height: 6 + 22 * level)
                    Text(ChordLabel.pitchNames[pitchClass])
                        .font(.system(size: 9, weight: isChordTone ? .bold : .regular, design: .rounded))
                        .foregroundStyle(isChordTone ? Theme.accentWarm : Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
            }
        }
        .frame(height: 44, alignment: .bottom)
        .animation(.linear(duration: 0.08), value: values)
    }
}
