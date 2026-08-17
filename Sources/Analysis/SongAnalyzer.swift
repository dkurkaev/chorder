import Foundation

/// Полный разбор фрагмента: хрома → аккорды → ритм → такты.
/// Чистый Foundation, без UI — можно гонять на любых сэмплах.
enum SongAnalyzer {

    static func analyze(
        samples: [Float],
        sampleRate: Double,
        chordOptions: ChordRecognizer.Options? = nil,
        separation: SourceSeparator.Mode? = .full
    ) -> AnalysisResult {
        let duration = Double(samples.count) / sampleRate
        guard duration > 0.5 else { return .empty }

        // Аккорды считаем по аккомпанементу: солирующая мелодия даёт ноты вне аккорда,
        // из-за которых распознаватель теряет аккорд или дёргается на соседний.
        // Ритм — по исходной записи: удары нужны целиком, их разделение только ослабляет.
        let harmony = separation.map {
            SourceSeparator.separate(samples: samples, sampleRate: sampleRate, mode: $0).accompaniment
        } ?? samples

        let chroma = ChromaExtractor.chromagram(samples: harmony, sampleRate: sampleRate)
        let beat = BeatTracker.analyze(samples: samples, sampleRate: sampleRate)
        let key = KeyEstimator.estimate(from: chroma)

        var beatOptions = chordOptions ?? ChordRecognizer.Options.beatSynchronous
        var frameOptions = ChordRecognizer.Options.default
        if let key {
            let context = ChordRecognizer.KeyContext(tonic: key.tonic, isMinor: key.isMinor)
            beatOptions.key = context
            frameOptions.key = context
        }

        // Разбор по долям устойчивее: хрома усредняется внутри доли, границы аккордов
        // попадают на сетку ритма. Без надёжного ритма падаем обратно на покадровый разбор.
        let chords: [ChordSegment]
        if beat.beats.count >= 4 {
            chords = ChordRecognizer.beatSynchronousSegments(
                frames: chroma, beats: beat.beats, duration: duration, options: beatOptions
            )
        } else {
            chords = ChordRecognizer.segments(from: chroma, duration: duration, options: frameOptions)
        }

        // Сетку тактов кладём на гармонию: сначала аккорд каждой доли, затем начало
        // осмысленной части и фаза, при которой границы тактов совпадают со сменой аккорда.
        let beatLabels = beatChords(beats: beat.beats, chords: chords, duration: duration)
        let firstBeat = firstMeaningfulBeat(
            beats: beat.beats,
            beatChords: beatLabels,
            beatsPerBar: beat.beatsPerBar,
            envelope: beat.onsetEnvelope,
            rate: beat.envelopeRate
        )
        let downbeatOffset = estimateBarStart(
            beats: beat.beats,
            beatChords: beatLabels,
            from: firstBeat,
            beatsPerBar: beat.beatsPerBar,
            envelope: beat.onsetEnvelope,
            rate: beat.envelopeRate
        )

        let bars = buildBars(
            beats: beat.beats,
            beatsPerBar: beat.beatsPerBar,
            startBeat: downbeatOffset,
            beatChords: beatLabels,
            duration: duration
        )

        // Лента и строка прогрессии должны показывать то же, что и такты: сетка уже
        // отбросила мусорное начало и убрала выбросы, и расходиться с ней нельзя.
        let finalChords = bars.isEmpty ? chords : segments(from: bars, source: chords)

        return AnalysisResult(
            duration: duration,
            bpm: (beat.bpm * 10).rounded() / 10,
            beatsPerBar: beat.beatsPerBar,
            beats: beat.beats,
            downbeatOffset: downbeatOffset,
            key: key?.name,
            chords: finalChords,
            bars: bars,
            tempoConfidence: beat.confidence
        )
    }

    /// Сворачивает доли тактов обратно в отрезки аккордов: подряд идущие одинаковые
    /// доли склеиваются. Уверенность берём у исходных отрезков, накрывающих этот кусок.
    static func segments(from bars: [Bar], source: [ChordSegment]) -> [ChordSegment] {
        var result: [ChordSegment] = []
        for bar in bars {
            let beatCount = bar.beatChords.count
            guard beatCount > 0 else { continue }
            let beatLength = (bar.end - bar.start) / Double(beatCount)
            for (index, label) in bar.beatChords.enumerated() {
                let start = bar.start + Double(index) * beatLength
                let end = index == beatCount - 1 ? bar.end : start + beatLength
                if var last = result.last, last.label == label, abs(last.end - start) < 1e-6 {
                    last.end = end
                    result[result.count - 1] = last
                } else {
                    result.append(ChordSegment(
                        label: label, start: start, end: end,
                        confidence: confidence(in: source, from: start, to: end)
                    ))
                }
            }
        }
        return result
    }

    private static func confidence(in source: [ChordSegment], from start: Double, to end: Double) -> Double {
        var weighted = 0.0
        var total = 0.0
        for segment in source {
            let overlap = min(end, segment.end) - max(start, segment.start)
            guard overlap > 0 else { continue }
            weighted += segment.confidence * overlap
            total += overlap
        }
        return total > 0 ? weighted / total : 0
    }

    // MARK: - Такты

    /// Аккорд каждой доли — тот, что занимает большую часть её длительности.
    static func beatChords(beats: [Double], chords: [ChordSegment], duration: Double) -> [ChordLabel] {
        guard !beats.isEmpty else { return [] }
        let fallbackLength = beats.count > 1 ? beats[1] - beats[0] : 0.5
        return beats.enumerated().map { index, start in
            let end = index + 1 < beats.count ? beats[index + 1] : min(duration, start + fallbackLength)
            return dominantChord(in: chords, from: start, to: end)
        }
    }

    /// Первая доля, с которой сетка тактов вообще имеет смысл.
    ///
    /// В начале записи почти всегда есть кусок, который к музыке не относится: тишина
    /// перед первым звуком, шум комнаты, счёт палочками. Аккордов там нет, а доли,
    /// которые туда поставил трекер, — догадка, и такты из них выглядят случайными.
    /// Поэтому берём максимум из двух признаков: первый распознанный аккорд и момент,
    /// с которого доли подкреплены онсетами.
    static func firstMeaningfulBeat(
        beats: [Double],
        beatChords: [ChordLabel],
        beatsPerBar: Int,
        envelope: [Float],
        rate: Double
    ) -> Int {
        guard !beats.isEmpty else { return 0 }
        // Ведёт гармония: аккорд не распознаётся ни в тишине, ни в шуме, поэтому первый
        // не пустой аккорд — самый надёжный признак того, что музыка началась.
        var start = beatChords.firstIndex { !$0.isNone } ?? 0

        // Онсеты — только страховка от аккорда, померещившегося в шуме: сдвигаем начало
        // вперёд, пока в такте нет ни одного заметного удара.
        let support = onsetSupport(beats: beats, envelope: envelope, rate: rate)
        if !support.isEmpty {
            let threshold = support.sorted()[support.count / 2] * 0.3
            while threshold > 0, start + beatsPerBar <= support.count,
                  support[start..<(start + beatsPerBar)].allSatisfy({ $0 < threshold }) {
                start += 1
            }
        }
        // Не съедаем запись целиком, если признаки разошлись: оставляем хотя бы один такт.
        return min(start, max(0, beats.count - beatsPerBar))
    }

    /// Сила онсета под каждой долей. Удар может слегка разъезжаться с сеткой,
    /// поэтому берём максимум по небольшой окрестности.
    private static func onsetSupport(beats: [Double], envelope: [Float], rate: Double) -> [Float] {
        guard !envelope.isEmpty, rate > 0 else { return [] }
        let window = max(1, Int(0.05 * rate))
        return beats.map { time in
            let frame = Int((time * rate).rounded())
            guard frame >= 0, frame < envelope.count else { return 0 }
            let lower = max(0, frame - window)
            let upper = min(envelope.count - 1, frame + window)
            return envelope[lower...upper].max() ?? 0
        }
    }

    /// Доля, с которой начинается первый такт.
    ///
    /// Перебираем все фазы внутри такта и выбираем ту, при которой такты ложатся на
    /// гармонию: аккорд держится весь такт, а смены попадают на границы, а не в середину.
    /// Онсеты — только тайбрейк: на записи с микрофона они врут чаще, чем гармония.
    static func estimateBarStart(
        beats: [Double],
        beatChords: [ChordLabel],
        from firstBeat: Int,
        beatsPerBar: Int,
        envelope: [Float],
        rate: Double
    ) -> Int {
        guard beats.count > firstBeat + beatsPerBar else { return firstBeat }

        var bestStart = firstBeat
        var bestScore = -Double.greatestFiniteMagnitude
        for phase in 0..<beatsPerBar {
            let start = firstBeat + phase
            guard start + beatsPerBar <= beats.count else { break }

            var score: Double = 0
            var index = start
            while index + beatsPerBar <= beatChords.count {
                let slice = beatChords[index..<(index + beatsPerBar)]
                let changesInside = zip(slice, slice.dropFirst()).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
                if changesInside == 0 && !(slice.first?.isNone ?? true) {
                    score += 1                      // такт целиком под одним аккордом
                } else {
                    score -= 0.35 * Double(changesInside)
                }
                if index > 0, beatChords[index] != beatChords[index - 1] {
                    score += 0.6                    // смена аккорда пришлась на границу такта
                }
                index += beatsPerBar
            }
            score += 0.15 * averageOnset(beats: beats, envelope: envelope, rate: rate,
                                         from: start, step: beatsPerBar)

            if score > bestScore {
                bestScore = score
                bestStart = start
            }
        }
        return bestStart
    }

    /// Средняя сила онсетов на границах тактов — нормирована, чтобы не зависеть от их числа.
    private static func averageOnset(
        beats: [Double], envelope: [Float], rate: Double, from start: Int, step: Int
    ) -> Double {
        guard !envelope.isEmpty, rate > 0, step > 0 else { return 0 }
        var sum: Double = 0
        var count = 0
        var index = start
        while index < beats.count {
            let frame = Int((beats[index] * rate).rounded())
            if frame >= 0, frame < envelope.count { sum += Double(envelope[frame]) }
            count += 1
            index += step
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// Смена аккорда почти никогда не попадает на границу такта ровно: распознаватель то
    /// немного опережает её, то запаздывает, и в такте остаётся «хвостик» в одну долю.
    /// Если такая одиночная доля совпадает с аккордом соседнего такта — это край смены,
    /// и её место там, а не здесь. Настоящие смены внутри такта (два аккорда по половине)
    /// правило не трогает: у них середина такта неоднородна.
    private static func snapChordEdges(
        _ labels: [ChordLabel], startBeat: Int, beatsPerBar: Int
    ) -> [ChordLabel] {
        guard beatsPerBar >= 3 else { return labels }
        var result = labels
        var index = startBeat
        while index + beatsPerBar <= labels.count {
            let first = index
            let last = index + beatsPerBar - 1
            let middle = labels[(first + 1)...(last - 1)]
            // Соседей читаем из исходного массива: правки соседнего такта не должны
            // тянуть за собой цепочку.
            // Середина такта однородна — значит такт держится под одним аккордом, а крайние
            // доли, выбивающиеся из него, это либо край смены, уехавший к соседу, либо
            // выброс на стыке аккордов. И то и другое место в такте не заслужило.
            if let core = middle.first, middle.allSatisfy({ $0 == core }), !core.isNone {
                if labels[last] != core { result[last] = core }
                if labels[first] != core { result[first] = core }
            }
            index += beatsPerBar
        }
        return result
    }

    static func buildBars(
        beats: [Double],
        beatsPerBar: Int,
        startBeat: Int,
        beatChords: [ChordLabel],
        duration: Double
    ) -> [Bar] {
        guard beats.count > startBeat + beatsPerBar else { return [] }
        let labels = snapChordEdges(beatChords, startBeat: startBeat, beatsPerBar: beatsPerBar)

        var bars: [Bar] = []
        var index = startBeat
        while index + beatsPerBar <= beats.count {
            let slice = Array(labels[index..<(index + beatsPerBar)])
            let start = beats[index]
            let endBeat = index + beatsPerBar
            let end = endBeat < beats.count ? beats[endBeat] : duration
            bars.append(Bar(index: 0, start: start, end: end, beatChords: slice))
            index += beatsPerBar
        }

        // Хвост записи так же бессмыслен, как и начало: пустые такты в конце убираем.
        while let last = bars.last, last.beatChords.allSatisfy({ $0.isNone }) {
            bars.removeLast()
        }
        return bars.enumerated().map { position, bar in
            var renumbered = bar
            renumbered.index = position
            return renumbered
        }
    }

    private static func dominantChord(in chords: [ChordSegment], from start: Double, to end: Double) -> ChordLabel {
        var best = ChordLabel.none
        var bestOverlap = 0.0
        for segment in chords {
            let overlap = min(end, segment.end) - max(start, segment.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = segment.label
            }
        }
        return best
    }
}
