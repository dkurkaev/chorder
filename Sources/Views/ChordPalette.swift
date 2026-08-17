import SwiftUI

/// Цвета аккордов, подобранные под конкретную запись.
///
/// Привязывать цвет к названию аккорда бессмысленно: в одной записи встретятся соседи по
/// квинтовому кругу и получат почти одинаковые оттенки, в другой — далёкие, и половина
/// палитры пропадёт зря. Здесь цвета раздаются по факту появления аккорда в записи,
/// из системной палитры и по порядку, разводящему соседей.
struct ChordPalette {
    private var colors: [ChordLabel: Color] = [:]

    /// Системная палитра Apple. Эти цвета выверены под тёмную и светлую темы и не
    /// выглядят самодельными; порядок подобран так, чтобы соседние в списке аккорды
    /// получали далёкие друг от друга оттенки.
    private static let systemColors: [Color] = [
        .blue, .orange, .green, .purple, .red, .teal,
        .indigo, .pink, .mint, .yellow, .cyan, .brown
    ]

    init(chords: [ChordLabel] = []) {
        let unique = chords.filter { !$0.isNone }.reduce(into: [ChordLabel]()) { result, chord in
            if !result.contains(chord) { result.append(chord) }
        }
        for (index, chord) in unique.enumerated() {
            colors[chord] = Self.systemColors[index % Self.systemColors.count]
        }
    }

    func color(for label: ChordLabel) -> Color {
        colors[label] ?? Color.white.opacity(0.18)
    }
}

private struct ChordPaletteKey: EnvironmentKey {
    static let defaultValue = ChordPalette()
}

extension EnvironmentValues {
    var chordPalette: ChordPalette {
        get { self[ChordPaletteKey.self] }
        set { self[ChordPaletteKey.self] = newValue }
    }
}
