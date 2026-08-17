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

    // MARK: - Сетка долей (динамическое программирование)

    static func trackBeats(envelope: [Float], rate: Double, periodFrames: Double, tightness: Float = 100) -> [Double] {
        guard periodFrames > 1, envelope.count > Int(periodFrames * 2) else { return [] }
        let period = periodFrames
        let searchStart = Int(-2 * period)
        let searchEnd = Int(-period / 2)
        guard searchStart <= searchEnd else { return [] }

        var cumulative = [Float](repeating: 0, count: envelope.count)
        var backlink = [Int](repeating: -1, count: envelope.count)

        // Предрасчёт штрафа за отклонение интервала от периода.
        var transitionCost = [Float](repeating: 0, count: searchEnd - searchStart + 1)
        for (i, offset) in (searchStart...searchEnd).enumerated() {
            transitionCost[i] = -tightness * Float(pow(log(Double(-offset) / period), 2))
        }

        for t in 0..<envelope.count {
            var bestScore = -Float.greatestFiniteMagnitude
            var bestIndex = -1
            for (i, offset) in (searchStart...searchEnd).enumerated() {
                let previous = t + offset
                guard previous >= 0 else { continue }
                let score = cumulative[previous] + transitionCost[i]
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
        let tailStart = max(0, envelope.count - Int(period))
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

        let beats = trackBeats(envelope: envelope, rate: rate, periodFrames: tempo.periodFrames)
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
            confidence: tempo.confidence
        )
    }
}
