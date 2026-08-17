import Foundation

/// Такт: доли и аккорды, выровненные по сетке ритма.
struct Bar: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var index: Int
    var start: Double
    var end: Double
    /// Аккорд на каждую долю такта.
    var beatChords: [ChordLabel]

    /// Уникальные аккорды такта по порядку — для компактного отображения.
    var uniqueChords: [ChordLabel] {
        var result: [ChordLabel] = []
        for chord in beatChords where result.last != chord {
            result.append(chord)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey { case id, index, start, end, beatChords }
}

struct AnalysisResult: Codable, Hashable {
    var duration: Double
    var bpm: Double
    var beatsPerBar: Int
    var beats: [Double]
    var downbeatOffset: Int
    var key: String?
    var chords: [ChordSegment]
    var bars: [Bar]
    var tempoConfidence: Double

    static let empty = AnalysisResult(
        duration: 0, bpm: 0, beatsPerBar: 4, beats: [], downbeatOffset: 0,
        key: nil, chords: [], bars: [], tempoConfidence: 0
    )

    var isEmpty: Bool { chords.isEmpty && beats.isEmpty }

    /// Аккорд, звучащий в момент `time`.
    func chord(at time: Double) -> ChordLabel? {
        chords.first { time >= $0.start && time < $0.end }?.label
    }

    /// Компактная строка последовательности: «C — Am — F — G».
    var progressionSummary: String {
        var unique: [String] = []
        for segment in chords where !segment.label.isNone {
            if unique.last != segment.label.name { unique.append(segment.label.name) }
        }
        return unique.joined(separator: " — ")
    }
}
