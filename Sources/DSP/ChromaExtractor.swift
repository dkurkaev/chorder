import Accelerate
import Foundation

struct ChromaFrame {
    /// 12 значений, C…B, нормированы на максимум (0…1).
    var values: [Float]
    /// Энергия тональной части кадра до нормировки — индикатор «есть ли гармония».
    var energy: Float
    /// Время центра окна, сек.
    var time: Double
}

/// Хромаграмма: спектр → отбеливание и выделение пиков → энергия по полутонам →
/// свёртка октав в 12 классов высоты.
///
/// Отбеливание критично для микрофонной записи: шум комнаты и АЧХ динамика
/// поднимают весь спектр, из-за чего хрома становится плоской и аккорд не отличить от шума.
enum ChromaExtractor {
    static let defaultFFTSize = 8192
    static let defaultHop = 2048

    /// Диапазон нот анализа (C2…C7): ниже плохое разрешение FFT, выше — в основном обертоны.
    static let lowestMIDI = 36
    static let highestMIDI = 96

    /// Полуширина окна фонового уровня, в бинах (~110 Гц при 8192/22050).
    private static let backgroundHalfWidth = 40

    static func chromagram(
        samples: [Float],
        sampleRate: Double,
        fftSize: Int = defaultFFTSize,
        hop: Int = defaultHop
    ) -> [ChromaFrame] {
        guard samples.count >= fftSize / 2 else { return [] }

        let fft = FFTProcessor(size: fftSize)
        let bands = noteBands(fftSize: fftSize, sampleRate: sampleRate)
        let binCount = fftSize / 2
        var frames: [ChromaFrame] = []
        frames.reserveCapacity(max(1, (samples.count - fftSize) / hop + 1))

        var spectrum = [Float](repeating: 0, count: binCount)
        var salience = [Float](repeating: 0, count: binCount)
        var start = 0

        while start + fftSize <= samples.count || (frames.isEmpty && start < samples.count) {
            let end = min(start + fftSize, samples.count)
            spectrum.withUnsafeMutableBufferPointer { buffer in
                fft.magnitudes(samples[start..<end], into: buffer.baseAddress!)
            }

            tonalSalience(spectrum: spectrum, into: &salience)

            var chroma = [Float](repeating: 0, count: 12)
            var total: Float = 0
            for band in bands {
                var energy: Float = 0
                for bin in band.lowBin...band.highBin {
                    energy += salience[bin]
                }
                chroma[band.pitchClass] += energy
                total += energy
            }

            // Логарифмическая компрессия — приглушает доминирование одного громкого тона.
            for i in 0..<12 { chroma[i] = log1pf(200 * chroma[i]) }
            enhanceContrast(&chroma)

            let time = (Double(start) + Double(fftSize) / 2) / sampleRate
            frames.append(ChromaFrame(values: chroma, energy: total, time: time))
            start += hop
        }

        smooth(&frames)
        return frames
    }

    /// Тональная «заметность» бина: превышение над локальным фоном, оставленное только на пиках.
    /// Шум и широкополосный гул дают ровный фон и после вычитания исчезают.
    private static func tonalSalience(spectrum: [Float], into salience: inout [Float]) {
        let count = spectrum.count
        let width = backgroundHalfWidth

        // Скользящее среднее по частоте = оценка фона.
        var prefix = [Float](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + spectrum[i] }

        for k in 0..<count {
            let lo = max(0, k - width)
            let hi = min(count - 1, k + width)
            let background = (prefix[hi + 1] - prefix[lo]) / Float(hi - lo + 1)
            let excess = spectrum[k] - background
            let isPeak = k > 0 && k < count - 1 && spectrum[k] >= spectrum[k - 1] && spectrum[k] >= spectrum[k + 1]
            salience[k] = (isPeak && excess > 0) ? excess : 0
        }
    }

    /// Контраст хромы: вычитаем медиану по 12 классам и нормируем.
    /// Плоский вектор (шум) после этого схлопывается почти в ноль, аккорд — нет.
    private static func enhanceContrast(_ chroma: inout [Float]) {
        let sorted = chroma.sorted()
        let median = sorted[6]
        for i in 0..<12 { chroma[i] = max(0, chroma[i] - median) }
        let peak = chroma.max() ?? 0
        guard peak > 0 else { return }
        for i in 0..<12 { chroma[i] /= peak }
    }

    /// Лёгкое сглаживание по времени (3 кадра ≈ 0.28 с) — гасит одиночные выбросы,
    /// но не размывает границы аккордов.
    private static func smooth(_ frames: inout [ChromaFrame]) {
        guard frames.count > 2 else { return }
        let source = frames
        for i in 1..<(frames.count - 1) {
            var values = [Float](repeating: 0, count: 12)
            for k in 0..<12 {
                values[k] = (source[i - 1].values[k] + source[i].values[k] * 2 + source[i + 1].values[k]) / 4
            }
            let peak = values.max() ?? 0
            if peak > 0 {
                for k in 0..<12 { values[k] /= peak }
            }
            frames[i].values = values
        }
    }

    private struct NoteBand {
        var pitchClass: Int
        var lowBin: Int
        var highBin: Int
    }

    private static func noteBands(fftSize: Int, sampleRate: Double) -> [NoteBand] {
        let binHz = sampleRate / Double(fftSize)
        let maxBin = fftSize / 2 - 1
        var bands: [NoteBand] = []
        for midi in lowestMIDI...highestMIDI {
            let center = 440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
            guard center < sampleRate / 2 else { break }
            let lower = center * pow(2.0, -0.5 / 12.0)
            let upper = center * pow(2.0, 0.5 / 12.0)
            var lowBin = Int(ceil(lower / binHz))
            var highBin = Int(floor(upper / binHz))
            if highBin < lowBin {
                // Полоса уже одного бина — берём ближайший.
                let nearest = Int((center / binHz).rounded())
                lowBin = nearest
                highBin = nearest
            }
            lowBin = max(1, min(lowBin, maxBin))
            highBin = max(lowBin, min(highBin, maxBin))
            bands.append(NoteBand(pitchClass: midi % 12, lowBin: lowBin, highBin: highBin))
        }
        return bands
    }
}
