import Foundation

enum ChordQuality: String, Codable, CaseIterable {
    case major
    case minor
    case dominant7
    case minor7
    case major7
    case diminished

    /// Интервалы от основного тона в полутонах.
    var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .dominant7: return [0, 4, 7, 10]
        case .minor7: return [0, 3, 7, 10]
        case .major7: return [0, 4, 7, 11]
        case .diminished: return [0, 3, 6]
        }
    }

    var suffix: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .dominant7: return "7"
        case .minor7: return "m7"
        case .major7: return "maj7"
        case .diminished: return "dim"
        }
    }

    /// Априорный вес: трезвучия встречаются чаще септаккордов.
    var prior: Float {
        switch self {
        case .major, .minor: return 1.0
        case .dominant7, .minor7: return 0.97
        case .major7: return 0.95
        case .diminished: return 0.92
        }
    }
}

/// Аккорд: основной тон 0…11 (C…B) + качество. `nil` root означает «нет аккорда».
struct ChordLabel: Codable, Hashable {
    var root: Int?
    var quality: ChordQuality?

    static let none = ChordLabel(root: nil, quality: nil)

    static let pitchNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    var isNone: Bool { root == nil || quality == nil }

    var name: String {
        guard let root, let quality else { return "—" }
        return ChordLabel.pitchNames[((root % 12) + 12) % 12] + quality.suffix
    }

    /// Короткая подпись для компактной сетки тактов.
    var shortName: String { name }
}

struct ChordSegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var label: ChordLabel
    var start: Double
    var end: Double
    /// Средняя уверенность (косинусная близость к шаблону) на отрезке.
    var confidence: Double

    var duration: Double { max(0, end - start) }

    private enum CodingKeys: String, CodingKey { case id, label, start, end, confidence }
}
