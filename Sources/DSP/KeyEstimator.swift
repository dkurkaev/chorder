import Foundation

/// Тональность методом Крумхансл — Шмуклер: корреляция усреднённой хромы с профилями лада.
enum KeyEstimator {
    private static let majorProfile: [Double] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88
    ]
    private static let minorProfile: [Double] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17
    ]

    struct Key {
        var tonic: Int
        var isMinor: Bool
        var correlation: Double

        var name: String {
            ChordLabel.pitchNames[((tonic % 12) + 12) % 12] + (isMinor ? "m" : "")
        }
    }

    /// Тональность по набору аккордов записи.
    ///
    /// Усреднённая хрома легко ошибается: она смешивает все ноты подряд, включая
    /// мелодию, и выдаёт тональность, которой в аккордах нет вовсе. Аккорды — куда более
    /// прямое свидетельство: тональность та, в чью диатонику укладывается больше всего
    /// звучащего времени. Относительные мажор и минор (например C и Am) неразличимы по
    /// набору аккордов вообще, поэтому спор между ними решает первый аккорд записи —
    /// с тоники песни обычно и начинаются.
    static func estimate(fromChords chords: [ChordSegment]) -> Key? {
        var weight: [ChordLabel: Double] = [:]
        for segment in chords where !segment.label.isNone {
            weight[segment.label, default: 0] += segment.duration
        }
        guard !weight.isEmpty else { return nil }
        let total = weight.values.reduce(0, +)
        guard total > 0 else { return nil }

        var scored: [(key: Key, score: Double)] = []
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                var fits = 0.0
                for (label, time) in weight where isDiatonic(label, tonic: tonic, isMinor: isMinor) {
                    fits += time
                }
                // Тоника, которая сама звучит, — дополнительный довод.
                let tonicChord = weight.first { $0.key.root == tonic && ($0.key.isMinorQuality == isMinor) }
                let bonus = (tonicChord?.value ?? 0) * 0.3
                scored.append((Key(tonic: tonic, isMinor: isMinor, correlation: (fits + bonus) / total),
                               fits + bonus))
            }
        }

        guard let peak = scored.map({ $0.score }).max(), peak > 0 else { return nil }
        let leaders = scored.filter { $0.score >= peak * 0.98 }
        if leaders.count == 1 { return leaders[0].key }

        // Спор равных решает первый аккорд записи.
        if let opening = chords.first(where: { !$0.label.isNone })?.label,
           let root = opening.root,
           let match = leaders.first(where: { $0.key.tonic == root && $0.key.isMinor == opening.isMinorQuality }) {
            return match.key
        }
        return leaders.max { $0.score < $1.score }?.key
    }

    private static func isDiatonic(_ label: ChordLabel, tonic: Int, isMinor: Bool) -> Bool {
        guard let root = label.root, let quality = label.quality else { return false }
        // Натуральный минор плюс повышенная VII ступень — иначе доминанта выпадает из лада.
        let scale: Set<Int> = isMinor ? [0, 2, 3, 5, 7, 8, 10, 11] : [0, 2, 4, 5, 7, 9, 11]
        return quality.intervals.allSatisfy { scale.contains((((root + $0 - tonic) % 12) + 12) % 12) }
    }

    static func estimate(from frames: [ChromaFrame]) -> Key? {
        guard !frames.isEmpty else { return nil }
        var average = [Double](repeating: 0, count: 12)
        for frame in frames {
            for i in 0..<12 { average[i] += Double(frame.values[i]) }
        }
        for i in 0..<12 { average[i] /= Double(frames.count) }

        var best: Key?
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let profile = isMinor ? minorProfile : majorProfile
                let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                let correlation = pearson(average, rotated)
                if best == nil || correlation > best!.correlation {
                    best = Key(tonic: tonic, isMinor: isMinor, correlation: correlation)
                }
            }
        }
        return best
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var numerator = 0.0, denomA = 0.0, denomB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            numerator += da * db
            denomA += da * da
            denomB += db * db
        }
        let denominator = sqrt(denomA * denomB)
        return denominator > 0 ? numerator / denominator : 0
    }
}
