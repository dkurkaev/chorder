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
    /// Индексы тактов, с которых начинается очередное проведение фразы. По ним разметка
    /// раскладывается строками так, чтобы одинаковые места фразы стояли друг под другом.
    var phraseStarts: [Int] = []

    static let empty = AnalysisResult(
        duration: 0, bpm: 0, beatsPerBar: 4, beats: [], downbeatOffset: 0,
        key: nil, chords: [], bars: [], tempoConfidence: 0, phraseStarts: []
    )

    // Разбор хранится в базе как JSON, поэтому у записей, сделанных прошлыми версиями,
    // новых полей просто нет. Значение по умолчанию тут не спасает: синтезированный
    // декодер требует ключ и без него роняет разбор целиком — читаем такие поля мягко.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decode(Double.self, forKey: .duration)
        bpm = try container.decode(Double.self, forKey: .bpm)
        beatsPerBar = try container.decode(Int.self, forKey: .beatsPerBar)
        beats = try container.decode([Double].self, forKey: .beats)
        downbeatOffset = try container.decode(Int.self, forKey: .downbeatOffset)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        chords = try container.decode([ChordSegment].self, forKey: .chords)
        bars = try container.decode([Bar].self, forKey: .bars)
        tempoConfidence = try container.decode(Double.self, forKey: .tempoConfidence)
        phraseStarts = try container.decodeIfPresent([Int].self, forKey: .phraseStarts) ?? []
    }

    init(
        duration: Double, bpm: Double, beatsPerBar: Int, beats: [Double], downbeatOffset: Int,
        key: String?, chords: [ChordSegment], bars: [Bar], tempoConfidence: Double,
        phraseStarts: [Int] = []
    ) {
        self.duration = duration
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.beats = beats
        self.downbeatOffset = downbeatOffset
        self.key = key
        self.chords = chords
        self.bars = bars
        self.tempoConfidence = tempoConfidence
        self.phraseStarts = phraseStarts
    }

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
