import Foundation

/// Повторяющаяся гармоническая фраза записи.
///
/// Песня почти всегда крутит одну и ту же короткую последовательность аккордов, но крутит
/// не механически: проведения укорачивают, элементы сжимают. Жёсткий цикл на такой записи
/// разъезжается сразу после первого сокращения, поэтому фраза не навязывается позиционно,
/// а выравнивается с записью — каждому элементу разрешено сжаться вдвое.
///
/// И сама фраза, и её длина берутся из записи: ничего заранее заданного здесь нет.
enum PhraseModel {

    struct Phrase {
        /// Аккорды фразы по порядку.
        var chords: [ChordLabel]
        /// Сколько долей занимает один элемент, когда фраза звучит целиком.
        var beatsPerChord: Int
        /// Доля тактов записи, которые фраза объясняет.
        var support: Double
    }

    /// Ищет фразу: самое частое окно из последовательности аккордов по тактам.
    ///
    /// Считаются все окна подряд, а не позиции по модулю длины, — иначе одно сокращение
    /// сбивает фазу и дальше всё считается несовпадением.
    /// Поворачивает кольцо так, чтобы фраза начиналась с заданного аккорда.
    ///
    /// Найденное окно — это кольцо: где его разрезать, поиск не знает, любой поворот для
    /// него одно и то же. Человеку фраза читается с того места, с которого песня её играет,
    /// поэтому разрезаем по первому такту записи.
    static func rotated(_ phrase: Phrase, toStartWith chord: ChordLabel) -> Phrase {
        guard let position = phrase.chords.firstIndex(of: chord), position > 0 else { return phrase }
        var rotated = phrase
        rotated.chords = Array(phrase.chords[position...] + phrase.chords[..<position])
        return rotated
    }

    static func find(barChords: [ChordLabel], beatsPerBar: Int, maxLength: Int = 8) -> Phrase? {
        let chords = barChords.filter { !$0.isNone }
        guard chords.count >= 4 else { return nil }

        var candidates: [Phrase] = []
        for length in 2...min(maxLength, chords.count / 2) {
            var counts: [[ChordLabel]: Int] = [:]
            for start in 0...(chords.count - length) {
                let window = Array(chords[start..<(start + length)])
                // Фраза из одного повторяющегося аккорда ничего не объясняет.
                guard Set(window).count > 1 else { continue }
                counts[window, default: 0] += 1
            }
            guard var (window, count) = counts.max(by: { $0.value < $1.value }), count >= 2 else { continue }
            window = shortestPeriod(of: window)

            // Насколько эта фраза покрывает запись: сколько тактов попадает в её вхождения.
            let support = Double(count * length) / Double(chords.count)
            candidates.append(Phrase(chords: window, beatsPerChord: beatsPerBar, support: support))
        }

        // Из фраз с почти одинаковым покрытием берём самую короткую: длинная обычно
        // оказывается склейкой двух проведений, и выравнивание с ней теряет гибкость.
        guard let bestSupport = candidates.map({ $0.support }).max() else { return nil }
        return candidates
            .filter { $0.support >= bestSupport * 0.95 }
            .min { $0.chords.count < $1.chords.count }
    }

    /// Ожидаемый аккорд для каждой доли — выравниванием записи с повторами фразы.
    ///
    /// Динамическое программирование по долям: каждый элемент фразы занимает либо свою
    /// полную длину, либо половину. Возвращает `nil`, если фраза объясняет запись плохо —
    /// значит гармония здесь не циклическая и подгонять нечего.
    static func expectedChords(
        phrase: Phrase, beatChords: [ChordLabel], minAgreement: Double = 0.55
    ) -> [ChordLabel]? {
        let count = beatChords.count
        let elements = phrase.chords.count
        guard count > phrase.beatsPerChord * 2, elements > 1 else { return nil }

        let full = phrase.beatsPerChord
        let half = max(1, full / 2)
        let lengths = full == half ? [full] : [full, half]

        // cost[t][j] — лучшая стоимость покрытия первых t долей, если только что закончился
        // элемент фразы j. Фраза циклическая, поэтому j считается по модулю.
        let infinity = Double.greatestFiniteMagnitude / 4
        var cost = [[Double]](repeating: [Double](repeating: infinity, count: elements), count: count + 1)
        var back = [[(t: Int, j: Int, length: Int)?]](
            repeating: [(t: Int, j: Int, length: Int)?](repeating: nil, count: elements), count: count + 1
        )

        for j in 0..<elements {
            for length in lengths where length <= count {
                cost[length][j] = mismatch(beatChords, from: 0, count: length, chord: phrase.chords[j])
                    + shrinkPenalty(length: length, full: full)
                back[length][j] = nil
            }
        }

        for t in 1...count {
            for j in 0..<elements where cost[t][j] < infinity {
                let next = (j + 1) % elements
                for length in lengths where t + length <= count {
                    let candidate = cost[t][j]
                        + mismatch(beatChords, from: t, count: length, chord: phrase.chords[next])
                        + shrinkPenalty(length: length, full: full)
                    if candidate < cost[t + length][next] {
                        cost[t + length][next] = candidate
                        back[t + length][next] = (t: t, j: j, length: length)
                    }
                }
            }
        }

        // Финал — там, где покрыта вся запись (или почти вся: хвост короче элемента).
        var bestEnd = 0
        var bestElement = 0
        var bestCost = infinity
        for t in max(1, count - full)...count {
            for j in 0..<elements where cost[t][j] < bestCost {
                bestCost = cost[t][j]
                bestEnd = t
                bestElement = j
            }
        }
        guard bestCost < infinity else { return nil }

        var expected = [ChordLabel](repeating: .none, count: count)
        var t = bestEnd
        var j = bestElement
        while t > 0 {
            let step = back[t][j]
            let length = step?.length ?? t
            for position in max(0, t - length)..<t { expected[position] = phrase.chords[j] }
            guard let step else { break }
            t = step.t
            j = step.j
        }

        // Если выравнивание согласно с записью меньше чем наполовину — фраза не та.
        let agreement = zip(expected, beatChords).filter { $0 == $1 }.count
        guard Double(agreement) / Double(count) >= minAgreement else { return nil }
        return expected
    }

    private static func mismatch(
        _ observed: [ChordLabel], from start: Int, count length: Int, chord: ChordLabel
    ) -> Double {
        var penalty = 0.0
        for index in start..<min(observed.count, start + length) where observed[index] != chord {
            // Пустая доля спорит с фразой слабее, чем уверенно распознанный чужой аккорд.
            penalty += observed[index].isNone ? 0.4 : 1
        }
        return penalty
    }

    /// Если найденное окно — это одна и та же фраза, повторённая дважды, работать надо
    /// с коротким вариантом: чем короче период, тем гибче выравнивание к сокращениям.
    private static func shortestPeriod(of window: [ChordLabel]) -> [ChordLabel] {
        for period in 1..<window.count where window.count % period == 0 {
            let head = Array(window[0..<period])
            var repeats = true
            for start in stride(from: period, to: window.count, by: period)
            where Array(window[start..<(start + period)]) != head {
                repeats = false
                break
            }
            if repeats { return head }
        }
        return window
    }

    /// Сжатие — приём законный, но редкий: без штрафа выравнивание начнёт кромсать фразу
    /// везде, где запись хоть немного не совпала.
    private static func shrinkPenalty(length: Int, full: Int) -> Double {
        length == full ? 0 : 0.75
    }
}
