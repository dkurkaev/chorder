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

    /// Ищет фразу: находит период повторения и берёт то проведение, которое разобрано
    /// увереннее остальных.
    ///
    /// Самое частое окно тут не годится: если каждый аккорд занимает по несколько тактов,
    /// а часть проведений искажена, точных повторов может не оказаться вовсе. Зато период
    /// виден по совпадениям со сдвигом, а среди одинаковых по смыслу проведений всегда есть
    /// более чистое — его и берём за образец, вместо того чтобы усреднять с испорченными.
    /// Несколько правдоподобных фраз — какая из них верна, решает уже итоговый разбор.
    ///
    /// Способы дополняют друг друга: частое окно надёжно там, где проведения повторяются
    /// дословно, но пасует, если каждое из них чем-то испорчено; поиск по периоду работает
    /// и в этом случае, зато сбивается на записях с сокращениями, где период «плавает».
    static func candidates(
        barChords: [ChordLabel], barSteadiness: [Double] = [], beatsPerBar: Int, maxLength: Int = 12
    ) -> [Phrase] {
        var result: [Phrase] = []
        if let byPeriod = find(
            barChords: barChords, barSteadiness: barSteadiness,
            beatsPerBar: beatsPerBar, maxLength: maxLength
        ) {
            result.append(byPeriod)
        }
        result.append(contentsOf: frequentWindows(
            barChords: barChords, beatsPerBar: beatsPerBar, maxLength: maxLength
        ))

        // Разные способы часто дают одну и ту же фразу — повторы ни к чему.
        var seen: Set<String> = []
        return result.filter { seen.insert(name(of: $0.chords)).inserted }
    }

    /// Самое частое дословное повторение — по одному кандидату на каждую длину.
    private static func frequentWindows(
        barChords: [ChordLabel], beatsPerBar: Int, maxLength: Int
    ) -> [Phrase] {
        let chords = barChords.filter { !$0.isNone }
        guard chords.count >= 4 else { return [] }

        var result: [Phrase] = []
        for length in 2...min(maxLength, chords.count / 2) {
            var counts: [[ChordLabel]: Int] = [:]
            for start in 0...(chords.count - length) {
                let window = Array(chords[start..<(start + length)])
                guard Set(window).count > 1 else { continue }
                counts[window, default: 0] += 1
            }
            // Обход словаря не упорядочен: при равном числе вхождений выбираем по имени,
            // иначе разбор одной записи давал бы от запуска к запуску разный результат.
            guard let best = counts
                .map({ (window: $0.key, count: $0.value) })
                .min(by: { ($0.count, name(of: $1.window)) > ($1.count, name(of: $0.window)) }),
                best.count >= 2 else { continue }
            result.append(Phrase(
                chords: shortestPeriod(of: best.window), beatsPerChord: beatsPerBar,
                support: Double(best.count * length) / Double(chords.count)
            ))
        }
        return result
    }

    static func find(
        barChords: [ChordLabel], barSteadiness: [Double] = [], beatsPerBar: Int, maxLength: Int = 12
    ) -> Phrase? {
        let count = barChords.count
        guard count >= 4 else { return nil }
        let steadiness = barSteadiness.count == count
            ? barSteadiness
            : [Double](repeating: 1, count: count)

        // Период: сдвиг, при котором запись больше всего похожа сама на себя.
        var agreements: [(period: Int, value: Double)] = []
        for period in 2...min(maxLength, count / 2) {
            var matches = 0
            var total = 0
            for index in 0..<(count - period) {
                guard !barChords[index].isNone, !barChords[index + period].isNone else { continue }
                total += 1
                if barChords[index] == barChords[index + period] { matches += 1 }
            }
            guard total > 0 else { continue }
            agreements.append((period, Double(matches) / Double(total)))
        }
        // Кратный период похож на себя не хуже исходного: если запись повторяется каждые
        // четыре такта, она повторяется и каждые восемь. Берём самый короткий из тех, что
        // объясняют запись почти так же хорошо, — длинный лишь склеивает проведения.
        guard let peak = agreements.map({ $0.value }).max(), peak >= 0.5,
              let chosen = agreements.filter({ $0.value >= peak * 0.95 }).min(by: { $0.period < $1.period })
        else { return nil }
        let bestPeriod = chosen.period
        let bestAgreement = chosen.value

        // Проведения фразы — блоки длиной в период. Берём самый уверенно разобранный.
        var bestStart = 0
        var bestScore = -Double.infinity
        var start = 0
        while start + bestPeriod <= count {
            let block = start..<(start + bestPeriod)
            guard barChords[block].allSatisfy({ !$0.isNone }) else { start += 1; continue }
            let score = steadiness[block].reduce(0, +) / Double(bestPeriod)
                + regularity(of: Array(barChords[block]))
            if score > bestScore {
                bestScore = score
                bestStart = start
            }
            start += 1
        }
        guard bestScore > -Double.infinity else { return nil }

        let window = shortestPeriod(of: Array(barChords[bestStart..<(bestStart + bestPeriod)]))
        return Phrase(chords: window, beatsPerChord: beatsPerBar, support: bestAgreement)
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

    /// Насколько ровно в блоке сменяются аккорды: держатся ли они одинаковое время.
    ///
    /// Там, где распознавание сбоит, аккорд дробится или обрывается раньше времени, и длины
    /// расходятся. Проведение с ровным гармоническим шагом почти всегда и есть верное.
    private static func regularity(of block: [ChordLabel]) -> Double {
        var lengths: [Double] = []
        var index = 0
        while index < block.count {
            var end = index
            while end + 1 < block.count && block[end + 1] == block[index] { end += 1 }
            lengths.append(Double(end - index + 1))
            index = end + 1
        }
        guard lengths.count > 1 else { return 0 }
        let mean = lengths.reduce(0, +) / Double(lengths.count)
        guard mean > 0 else { return 0 }
        let variance = lengths.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lengths.count)
        return 1 / (1 + sqrt(variance) / mean)
    }

    private static func name(of window: [ChordLabel]) -> String {
        window.map { $0.name }.joined(separator: " ")
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
    static var shrinkCost = 0.75

    private static func shrinkPenalty(length: Int, full: Int) -> Double {
        length == full ? 0 : shrinkCost
    }
}
