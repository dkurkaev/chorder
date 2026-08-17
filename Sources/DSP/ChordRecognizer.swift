import Foundation

/// Распознавание аккордов: косинусная близость хромы к шаблонам с обертонами
/// + сглаживание по Витерби (штраф за смену аккорда).
enum ChordRecognizer {

    // MARK: - Шаблоны

    struct Template {
        var label: ChordLabel
        var vector: [Float]   // нормирован по L2
        var prior: Float
    }

    /// Сдвиги обертонов 1…6 в полутонах и их веса.
    private static let harmonicSemitones = [0, 12, 19, 24, 28, 31]
    private static let harmonicWeights: [Float] = [1.0, 0.55, 0.35, 0.24, 0.16, 0.12]

    static let templates: [Template] = buildTemplates()

    private static func buildTemplates() -> [Template] {
        var result: [Template] = []
        for quality in ChordQuality.allCases {
            for root in 0..<12 {
                var vector = [Float](repeating: 0, count: 12)
                for interval in quality.intervals {
                    for (index, semitone) in harmonicSemitones.enumerated() {
                        vector[(root + interval + semitone) % 12] += harmonicWeights[index]
                    }
                }
                normalizeL2(&vector)
                result.append(Template(
                    label: ChordLabel(root: root, quality: quality),
                    vector: vector,
                    prior: quality.prior
                ))
            }
        }
        return result
    }

    private static func normalizeL2(_ v: inout [Float]) {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sqrt(sum)
        guard norm > 0 else { return }
        for i in 0..<v.count { v[i] /= norm }
    }

    // MARK: - Покадровые оценки

    /// Контекст тональности: диатонические аккорды получают небольшую фору.
    struct KeyContext {
        var tonic: Int
        var isMinor: Bool
        var boost: Float = 1.06

        /// Натуральный минор + повышенная VII ступень (чтобы E7 в Am считался «своим»).
        var scale: Set<Int> {
            isMinor ? [0, 2, 3, 5, 7, 8, 10, 11] : [0, 2, 4, 5, 7, 9, 11]
        }

        func contains(_ label: ChordLabel) -> Bool {
            guard let root = label.root, let quality = label.quality else { return false }
            let degrees = scale
            return quality.intervals.allSatisfy { degrees.contains(((root + $0 - tonic) % 12 + 12) % 12) }
        }
    }

    /// Косинусная близость кадра ко всем 72 шаблонам.
    static func scores(for frame: [Float], key: KeyContext? = nil) -> [Float] {
        var normalized = frame
        normalizeL2(&normalized)

        var out = [Float](repeating: 0, count: templates.count)
        for (i, template) in templates.enumerated() {
            var dot: Float = 0
            for k in 0..<12 { dot += normalized[k] * template.vector[k] }
            var score = max(0, dot) * template.prior
            if let key, key.contains(template.label) { score *= key.boost }
            out[i] = score
        }
        return out
    }

    /// Лучший аккорд одного кадра — для лайв-индикатора.
    static func bestLabel(for frame: [Float], noChordScore: Float = Options.default.noChordScore)
        -> (label: ChordLabel, confidence: Float) {
        let s = scores(for: frame)
        guard !s.isEmpty else { return (.none, 0) }
        var bestIndex = 0
        for i in 1..<s.count where s[i] > s[bestIndex] { bestIndex = i }
        if s[bestIndex] < noChordScore { return (.none, s[bestIndex]) }
        return (templates[bestIndex].label, s[bestIndex])
    }

    // MARK: - Витерби

    struct Options {
        /// Во сколько раз растягиваются различия косинусных близостей.
        var emissionGain: Float = 28
        /// Штраф за смену аккорда между соседними кадрами.
        var changePenalty: Float = 3.2
        /// Минимальная длительность сегмента, сек.
        var minSegmentDuration: Double = 0.28
        /// Порог косинусной близости, ниже которого кадр считается «нет аккорда».
        var noChordScore: Float = 0.72
        /// Доля от медианной энергии, ниже которой кадр считается тишиной.
        var silenceRatio: Float = 0.08
        /// Тональность фрагмента, если известна — диатоника получает фору.
        var key: KeyContext?

        static let `default` = Options()

        /// Для анализа по долям: кадр длиннее (≈0.5 с), поэтому смена аккорда дешевле,
        /// а минимальный сегмент — примерно одна доля.
        static let beatSynchronous = Options(
            emissionGain: 28,
            // Подобрано по реальной микрофонной записи: при 1.6 аккорд «дрожал»
            // почти на каждой доле, при 8 склеивались разные аккорды.
            changePenalty: 4.5,
            minSegmentDuration: 0.45,
            noChordScore: 0.72,
            silenceRatio: 0.08
        )
    }

    /// Последовательность аккордов по долям: хрома усредняется внутри доли,
    /// поэтому границы аккордов автоматически ложатся на сетку ритма.
    static func beatSynchronousSegments(
        frames: [ChromaFrame],
        beats: [Double],
        duration: Double,
        options: Options = .beatSynchronous
    ) -> [ChordSegment] {
        guard beats.count >= 2, !frames.isEmpty else { return [] }

        // Границы «долевых» окон: от начала записи до конца, с долями внутри.
        var boundaries = beats
        if let first = boundaries.first, first > 0.05 { boundaries.insert(0, at: 0) }
        if let last = boundaries.last, last < duration - 0.05 { boundaries.append(duration) }

        var beatFrames: [ChromaFrame] = []
        beatFrames.reserveCapacity(boundaries.count - 1)
        var keptBoundaries: [Double] = []

        for i in 0..<(boundaries.count - 1) {
            let start = boundaries[i]
            let end = boundaries[i + 1]
            let inside = frames.filter { $0.time >= start && $0.time < end }
            let source = inside.isEmpty
                ? [frames.min(by: { abs($0.time - start) < abs($1.time - start) })!]
                : inside

            var values = [Float](repeating: 0, count: 12)
            var energy: Float = 0
            for frame in source {
                for k in 0..<12 { values[k] += frame.values[k] }
                energy += frame.energy
            }
            let count = Float(source.count)
            for k in 0..<12 { values[k] /= count }
            let peak = values.max() ?? 0
            if peak > 0 {
                for k in 0..<12 { values[k] /= peak }
            }
            beatFrames.append(ChromaFrame(values: values, energy: energy / count, time: start))
            keptBoundaries.append(start)
        }
        keptBoundaries.append(boundaries[boundaries.count - 1])

        let path = viterbiPath(frames: beatFrames, options: options)
        return segments(
            path: path,
            starts: keptBoundaries,
            frames: beatFrames,
            options: options,
            minDuration: options.minSegmentDuration
        )
    }

    /// Последовательность аккордов по хромаграмме (без опоры на ритм).
    static func segments(
        from frames: [ChromaFrame],
        duration: Double,
        options: Options = .default
    ) -> [ChordSegment] {
        guard !frames.isEmpty else { return [] }
        let hopTime = frames.count > 1 ? frames[1].time - frames[0].time : 0.1
        var starts = frames.map { max(0, $0.time - hopTime / 2) }
        starts.append(min(duration, (frames.last?.time ?? 0) + hopTime / 2))

        let path = viterbiPath(frames: frames, options: options)
        return segments(
            path: path,
            starts: starts,
            frames: frames,
            options: options,
            minDuration: options.minSegmentDuration
        )
    }

    /// Оптимальная цепочка состояний: 72 аккорда + «нет аккорда».
    private static func viterbiPath(frames: [ChromaFrame], options: Options) -> [Int] {
        guard !frames.isEmpty else { return [] }

        let stateCount = templates.count + 1
        let noneState = templates.count

        let sortedEnergies = frames.map { $0.energy }.sorted()
        let medianEnergy = sortedEnergies[sortedEnergies.count / 2]
        let silenceThreshold = medianEnergy * options.silenceRatio

        var emissions: [[Float]] = []
        emissions.reserveCapacity(frames.count)
        for frame in frames {
            var s = scores(for: frame.values, key: options.key)
            s.append(options.noChordScore)
            if frame.energy < silenceThreshold {
                for i in 0..<noneState { s[i] = 0 }
                s[noneState] = 1
            }
            for i in 0..<stateCount { s[i] *= options.emissionGain }
            emissions.append(s)
        }

        // Прямой проход. Переход «в любое другое состояние» стоит одинаково,
        // поэтому достаточно знать лучшее предыдущее состояние — O(T·S).
        var cost = emissions[0]
        var backpointers = [[Int32]](repeating: [Int32](repeating: 0, count: stateCount), count: frames.count)

        for t in 1..<frames.count {
            var bestPrev: Float = -.greatestFiniteMagnitude
            var bestPrevIndex = 0
            for s in 0..<stateCount where cost[s] > bestPrev {
                bestPrev = cost[s]
                bestPrevIndex = s
            }

            var next = [Float](repeating: 0, count: stateCount)
            for s in 0..<stateCount {
                let stay = cost[s]
                let switchTo = bestPrev - options.changePenalty
                if stay >= switchTo {
                    next[s] = stay + emissions[t][s]
                    backpointers[t][s] = Int32(s)
                } else {
                    next[s] = switchTo + emissions[t][s]
                    backpointers[t][s] = Int32(bestPrevIndex)
                }
            }
            cost = next
        }

        // Обратный проход
        var path = [Int](repeating: 0, count: frames.count)
        var current = 0
        for s in 1..<stateCount where cost[s] > cost[current] { current = s }
        path[frames.count - 1] = current
        var t = frames.count - 1
        while t > 0 {
            current = Int(backpointers[t][current])
            path[t - 1] = current
            t -= 1
        }

        return path
    }

    /// Путь состояний + границы окон → сегменты аккордов.
    /// `starts` содержит на один элемент больше, чем кадров: последний — конец записи.
    private static func segments(
        path: [Int],
        starts: [Double],
        frames: [ChromaFrame],
        options: Options,
        minDuration: Double
    ) -> [ChordSegment] {
        guard !path.isEmpty, starts.count == path.count + 1 else { return [] }
        let noneState = templates.count

        var result: [ChordSegment] = []
        var index = 0
        while index < path.count {
            var j = index
            var confidenceSum: Double = 0
            while j < path.count && path[j] == path[index] {
                let state = path[index]
                let score = state == noneState
                    ? Double(options.noChordScore)
                    : Double(scores(for: frames[j].values, key: options.key)[state])
                confidenceSum += score
                j += 1
            }
            let state = path[index]
            result.append(ChordSegment(
                label: state == noneState ? .none : templates[state].label,
                start: starts[index],
                end: starts[j],
                confidence: confidenceSum / Double(j - index)
            ))
            index = j
        }
        return mergeShortSegments(result, minDuration: minDuration)
    }

    private static func mergeShortSegments(_ segments: [ChordSegment], minDuration: Double) -> [ChordSegment] {
        guard segments.count > 1 else { return segments }
        var result = segments

        var changed = true
        while changed && result.count > 1 {
            changed = false
            for i in 0..<result.count where result[i].duration < minDuration {
                // Короткий сегмент поглощается более длинным соседом.
                let prevDuration = i > 0 ? result[i - 1].duration : -1
                let nextDuration = i + 1 < result.count ? result[i + 1].duration : -1
                if prevDuration >= 0 && prevDuration >= nextDuration {
                    result[i - 1].end = result[i].end
                    result.remove(at: i)
                } else if nextDuration >= 0 {
                    result[i + 1].start = result[i].start
                    result.remove(at: i)
                } else {
                    break
                }
                changed = true
                break
            }
        }

        // Склейка одинаковых соседей
        var merged: [ChordSegment] = []
        for segment in result {
            if var last = merged.last, last.label == segment.label {
                last.end = segment.end
                last.confidence = (last.confidence + segment.confidence) / 2
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged
    }
}
