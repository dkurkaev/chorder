import Foundation

struct BeatResult {
    var bpm: Double
    /// Времена долей, сек.
    var beats: [Double]
    /// Индекс первой сильной доли (0…beatsPerBar-1).
    var downbeatOffset: Int
    var beatsPerBar: Int
    /// Огибающая онсетов и её частота кадров — для визуализации и выравнивания.
    var onsetEnvelope: [Float]
    var envelopeRate: Double
    /// Насколько уверенно найден темп (0…1).
    var confidence: Double
    /// Период доли в кадрах огибающей — нужен, чтобы перестроить сетку в другой октаве.
    var periodFrames: Double = 0

    static let empty = BeatResult(
        bpm: 0, beats: [], downbeatOffset: 0, beatsPerBar: 4,
        onsetEnvelope: [], envelopeRate: 0, confidence: 0
    )
}

/// Темп и сетка долей:
/// spectral flux → автокорреляция с лог-нормальным приором → DP beat tracking (Ellis, 2007).
enum BeatTracker {
    static let fftSize = 1024
    static let hop = 256

    static let minBPM = 60.0
    static let maxBPM = 200.0

    // MARK: - Огибающая онсетов

    static func onsetEnvelope(samples: [Float], sampleRate: Double) -> (envelope: [Float], rate: Double) {
        let rate = sampleRate / Double(hop)
        guard samples.count >= fftSize else { return ([], rate) }

        let fft = FFTProcessor(size: fftSize)
        let bins = fftSize / 2
        var previous = [Float](repeating: 0, count: bins)
        var current = [Float](repeating: 0, count: bins)
        var envelope: [Float] = []
        envelope.reserveCapacity((samples.count - fftSize) / hop + 1)

        var start = 0
        var isFirst = true
        while start + fftSize <= samples.count {
            current.withUnsafeMutableBufferPointer { buf in
                fft.magnitudes(samples[start..<(start + fftSize)], into: buf.baseAddress!)
            }
            var flux: Float = 0
            for k in 1..<bins {
                let value = log1pf(1000 * current[k])
                let diff = value - previous[k]
                if diff > 0 { flux += diff }
                previous[k] = value
            }
            envelope.append(isFirst ? 0 : flux)
            isFirst = false
            start += hop
        }

        normalize(&envelope, rate: rate)
        return (envelope, rate)
    }

    /// Вычитание скользящего среднего (окно ~0.4 с) + нормировка на СКО.
    private static func normalize(_ envelope: inout [Float], rate: Double) {
        guard !envelope.isEmpty else { return }
        let window = max(3, Int(0.4 * rate))
        let half = window / 2
        var smoothed = [Float](repeating: 0, count: envelope.count)
        var runningSum: Float = 0
        var queueStart = 0
        for i in 0..<envelope.count {
            runningSum += envelope[i]
            let lo = max(0, i - half)
            while queueStart < lo {
                runningSum -= envelope[queueStart]
                queueStart += 1
            }
            smoothed[i] = runningSum / Float(i - queueStart + 1)
        }
        for i in 0..<envelope.count {
            envelope[i] = max(0, envelope[i] - smoothed[i])
        }

        let mean = envelope.reduce(0, +) / Float(envelope.count)
        var variance: Float = 0
        for x in envelope { variance += (x - mean) * (x - mean) }
        let std = sqrt(variance / Float(envelope.count))
        guard std > 0 else { return }
        for i in 0..<envelope.count { envelope[i] /= std }
    }

    // MARK: - Темп

    /// Автокорреляция огибающей с приором на «привычные» темпы.
    static func estimateTempo(envelope: [Float], rate: Double) -> (bpm: Double, periodFrames: Double, confidence: Double) {
        guard envelope.count > 16 else { return (0, 0, 0) }
        let minLag = max(2, Int((60.0 / maxBPM) * rate))
        let maxLag = min(envelope.count - 1, Int((60.0 / minBPM) * rate))
        guard maxLag > minLag else { return (0, 0, 0) }

        var bestScore = -Float.greatestFiniteMagnitude
        var bestLag = minLag
        var scores = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var sum: Float = 0
            for i in lag..<envelope.count {
                sum += envelope[i] * envelope[i - lag]
            }
            sum /= Float(envelope.count - lag)

            let bpm = 60.0 * rate / Double(lag)
            // Лог-нормальный приор вокруг 120 BPM — снимает ошибки «в два раза».
            let weight = Float(exp(-0.5 * pow(log2(bpm / 120.0) / 0.9, 2)))
            let score = sum * weight
            scores[lag] = score
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        // Уточнение пика параболой по трём точкам.
        var refinedLag = Double(bestLag)
        if bestLag > minLag && bestLag < maxLag {
            let y0 = Double(scores[bestLag - 1])
            let y1 = Double(scores[bestLag])
            let y2 = Double(scores[bestLag + 1])
            let denominator = y0 - 2 * y1 + y2
            if abs(denominator) > 1e-9 {
                let delta = 0.5 * (y0 - y2) / denominator
                if abs(delta) < 1 { refinedLag += delta }
            }
        }

        let mean = scores[minLag...maxLag].reduce(0, +) / Float(maxLag - minLag + 1)
        let confidence = mean > 0 ? Double(min(1, bestScore / (mean * 3))) : 0
        return (60.0 * rate / refinedLag, refinedLag, confidence)
    }

    // MARK: - Локальный темп

    /// Период доли для каждого кадра огибающей.
    ///
    /// Считаем автокорреляцию в скользящем окне и ищем пик рядом с глобальной оценкой:
    /// уходить далеко нельзя, иначе на слабом куске окно поймает половинный или двойной
    /// период и сетка порвётся. Результат сглаживается — темп меняется плавно.
    static func localPeriods(
        envelope: [Float], rate: Double, globalPeriod: Double, tolerance: Double = 0.10
    ) -> [Double] {
        let count = envelope.count
        guard count > 8, globalPeriod > 1 else {
            return [Double](repeating: globalPeriod, count: max(0, count))
        }

        let windowFrames = max(Int(globalPeriod * 8), Int(4 * rate))
        let step = max(1, Int(rate / 2))
        let minLag = max(2, Int(globalPeriod * (1 - tolerance)))
        let maxLag = min(count - 1, Int(globalPeriod * (1 + tolerance)) + 1)
        guard maxLag > minLag else { return [Double](repeating: globalPeriod, count: count) }

        var anchors: [(frame: Int, period: Double)] = []
        var start = 0
        while start < count {
            let end = min(count, start + windowFrames)
            guard end - start > maxLag * 2 else { break }

            var bestScore = -Float.greatestFiniteMagnitude
            var bestLag = Int(globalPeriod)
            var scores = [Float](repeating: 0, count: maxLag + 1)
            for lag in minLag...maxLag {
                var sum: Float = 0
                for i in (start + lag)..<end { sum += envelope[i] * envelope[i - lag] }
                sum /= Float(end - start - lag)
                scores[lag] = sum
                if sum > bestScore {
                    bestScore = sum
                    bestLag = lag
                }
            }

            // Уточнение пика параболой — иначе период квантуется шагом в один кадр,
            // а это уже проценты темпа.
            var refined = Double(bestLag)
            if bestLag > minLag, bestLag < maxLag {
                let y0 = Double(scores[bestLag - 1])
                let y1 = Double(scores[bestLag])
                let y2 = Double(scores[bestLag + 1])
                let denominator = y0 - 2 * y1 + y2
                if abs(denominator) > 1e-9 {
                    let delta = 0.5 * (y0 - y2) / denominator
                    if abs(delta) < 1 { refined += delta }
                }
            }
            anchors.append((frame: (start + end) / 2, period: refined))
            start += step
        }

        guard anchors.count > 1 else { return [Double](repeating: globalPeriod, count: count) }
        smoothAnchors(&anchors)
        // Локальная оценка шумит: на тихом такте окно легко ошибается на пару процентов.
        // Тянем её к глобальной, чтобы отслеживать настоящий дрейф, а не дрожание метода.
        for i in 0..<anchors.count {
            anchors[i].period = globalPeriod + (anchors[i].period - globalPeriod) * 0.5
        }

        // Линейная интерполяция между опорными точками.
        var periods = [Double](repeating: globalPeriod, count: count)
        var index = 0
        for frame in 0..<count {
            while index + 1 < anchors.count && anchors[index + 1].frame < frame { index += 1 }
            if frame <= anchors[0].frame {
                periods[frame] = anchors[0].period
            } else if frame >= anchors[anchors.count - 1].frame {
                periods[frame] = anchors[anchors.count - 1].period
            } else {
                let left = anchors[index]
                let right = anchors[index + 1]
                let span = Double(right.frame - left.frame)
                let position = span > 0 ? Double(frame - left.frame) / span : 0
                periods[frame] = left.period + (right.period - left.period) * position
            }
        }
        return periods
    }

    /// Скользящая медиана по пяти опорным точкам — снимает выбросы на тихих кусках,
    /// где окно автокорреляции цепляется не за тот пик.
    private static func smoothAnchors(_ anchors: inout [(frame: Int, period: Double)]) {
        guard anchors.count > 2 else { return }
        let source = anchors
        for i in 0..<anchors.count {
            let lower = max(0, i - 2)
            let upper = min(source.count - 1, i + 2)
            var window = (lower...upper).map { source[$0].period }
            window.sort()
            anchors[i].period = window[window.count / 2]
        }
    }

    // MARK: - Сетка долей (динамическое программирование)

    static func trackBeats(envelope: [Float], rate: Double, periodFrames: Double, tightness: Float = 100) -> [Double] {
        trackBeats(envelope: envelope, rate: rate,
                   periods: [Double](repeating: periodFrames, count: envelope.count),
                   tightness: tightness)
    }

    /// Тот же DP, но период задаётся для каждого кадра отдельно.
    ///
    /// Живое исполнение не держит один темп: он плывёт на несколько процентов, и сетка,
    /// построенная от единственного BPM, к середине записи уезжает от музыки. Здесь
    /// ожидаемый интервал берётся локальный, поэтому доли следуют за исполнением.
    static func trackBeats(envelope: [Float], rate: Double, periods: [Double], tightness: Float = 100) -> [Double] {
        guard let maxPeriod = periods.max(), maxPeriod > 1,
              envelope.count > Int(maxPeriod * 2), periods.count == envelope.count else { return [] }
        let searchStart = Int(-2 * maxPeriod)
        let searchEnd = Int(-(periods.min() ?? maxPeriod) / 2)
        guard searchStart <= searchEnd else { return [] }

        var cumulative = [Float](repeating: 0, count: envelope.count)
        var backlink = [Int](repeating: -1, count: envelope.count)

        for t in 0..<envelope.count {
            var bestScore = -Float.greatestFiniteMagnitude
            var bestIndex = -1
            let period = periods[t]
            for offset in searchStart...searchEnd {
                let previous = t + offset
                guard previous >= 0 else { continue }
                // Штраф за отклонение фактического интервала от ожидаемого здесь и сейчас.
                let ratio = Double(-offset) / period
                guard ratio > 0.4, ratio < 2.5 else { continue }
                let penalty = -tightness * Float(pow(log(ratio), 2))
                let score = cumulative[previous] + penalty
                if score > bestScore {
                    bestScore = score
                    bestIndex = previous
                }
            }
            if bestIndex < 0 {
                cumulative[t] = envelope[t]
                backlink[t] = -1
            } else {
                cumulative[t] = envelope[t] + bestScore
                backlink[t] = bestIndex
            }
        }

        // Старт обратного прохода — лучший максимум в хвосте длиной в один период.
        let tailStart = max(0, envelope.count - Int(maxPeriod))
        var last = tailStart
        for t in tailStart..<envelope.count where cumulative[t] > cumulative[last] { last = t }

        var frames: [Int] = []
        var cursor = last
        while cursor >= 0 {
            frames.append(cursor)
            cursor = backlink[cursor]
        }
        frames.reverse()
        return frames.map { Double($0) / rate }
    }

    /// Сетка долей для заданного периода — чтобы проверить гипотезу «темп вдвое быстрее».
    ///
    /// Автокорреляция одинаково хорошо объясняет и период, и его кратные: если бочка бьёт
    /// через долю, половинный темп выглядит для неё не хуже настоящего. Разрешить этот
    /// спор по одной огибающей нельзя — решает уже гармония, см. SongAnalyzer.
    static func beats(envelope: [Float], rate: Double, periodFrames: Double) -> [Double] {
        guard periodFrames > 1 else { return [] }
        let periods = localPeriods(envelope: envelope, rate: rate, globalPeriod: periodFrames)
        return trackBeats(envelope: envelope, rate: rate, periods: periods)
    }

    /// Средний интервал между долями — итоговый BPM считаем по факту, а не по оценке.
    static func bpm(from beats: [Double], fallback: Double) -> Double {
        guard beats.count > 3 else { return fallback }
        var intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let median = intervals[intervals.count / 2]
        intervals = intervals.filter { abs($0 - median) < median * 0.25 }
        guard !intervals.isEmpty else { return fallback }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        return mean > 0 ? 60.0 / mean : fallback
    }

    // MARK: - Сильная доля

    /// Фаза такта: доля с наибольшей суммарной энергией онсетов,
    /// с бонусом за совпадение со сменой аккорда.
    static func estimateDownbeat(
        beats: [Double],
        envelope: [Float],
        rate: Double,
        beatsPerBar: Int,
        chordChanges: [Double]
    ) -> Int {
        guard beats.count >= beatsPerBar, !envelope.isEmpty else { return 0 }
        var bestPhase = 0
        var bestScore = -Double.greatestFiniteMagnitude
        for phase in 0..<beatsPerBar {
            var score: Double = 0
            for (index, time) in beats.enumerated() where index % beatsPerBar == phase {
                let frame = Int((time * rate).rounded())
                if frame >= 0 && frame < envelope.count {
                    score += Double(envelope[frame])
                }
                if chordChanges.contains(where: { abs($0 - time) < 0.12 }) {
                    score += 1.5
                }
            }
            if score > bestScore {
                bestScore = score
                bestPhase = phase
            }
        }
        return bestPhase
    }

    // MARK: - Всё вместе

    static func analyze(samples: [Float], sampleRate: Double, chordChanges: [Double] = []) -> BeatResult {
        let (envelope, rate) = onsetEnvelope(samples: samples, sampleRate: sampleRate)
        guard !envelope.isEmpty else { return .empty }

        let tempo = estimateTempo(envelope: envelope, rate: rate)
        guard tempo.bpm > 0 else { return .empty }

        let periods = localPeriods(envelope: envelope, rate: rate, globalPeriod: tempo.periodFrames)
        let beats = trackBeats(envelope: envelope, rate: rate, periods: periods)
        let beatsPerBar = 4
        let downbeat = estimateDownbeat(
            beats: beats, envelope: envelope, rate: rate,
            beatsPerBar: beatsPerBar, chordChanges: chordChanges
        )

        // Уточняем BPM по фактическим межударным интервалам.
        var bpm = tempo.bpm
        if beats.count > 3 {
            var intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
            let median = intervals[intervals.count / 2]
            intervals = intervals.filter { abs($0 - median) < median * 0.25 }
            if !intervals.isEmpty {
                let mean = intervals.reduce(0, +) / Double(intervals.count)
                if mean > 0 { bpm = 60.0 / mean }
            }
        }

        return BeatResult(
            bpm: bpm,
            beats: beats,
            downbeatOffset: downbeat,
            beatsPerBar: beatsPerBar,
            onsetEnvelope: envelope,
            envelopeRate: rate,
            confidence: tempo.confidence,
            periodFrames: tempo.periodFrames
        )
    }
}
