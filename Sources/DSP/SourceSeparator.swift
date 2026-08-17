import Accelerate
import Foundation

/// Разделение записи на аккомпанемент и мелодию.
///
/// Аккордам мешает солирующий голос: он даёт ноты вне аккорда, из-за чего распознаватель
/// то теряет аккорд, то дёргается на соседний. Разделение идёт в два шага, оба —
/// на спектрограмме, без обучения и без сети:
///
/// 1. **HPSS.** Гармония держится во времени, но узкая по частоте; удар наоборот — широкий
///    по частоте и короткий. Медиана вдоль времени оставляет первое, медиана вдоль частоты —
///    второе. Отношение этих двух оценок даёт мягкую маску, которая снимает ударные.
/// 2. **REPET-SIM.** Аккомпанемент повторяется, мелодия — нет. Для каждого кадра ищем
///    несколько наиболее похожих кадров в другом месте записи и берём поэлементную медиану:
///    то, что повторилось, — фон. Остаток — солирующая партия.
///
/// Отдаются оба сигнала: аккорды считаются по аккомпанементу, а мелодия понадобится
/// отдельному разбору мелодии.
enum SourceSeparator {

    struct Separated {
        var accompaniment: [Float]
        var melody: [Float]
    }

    enum Mode {
        /// Только снятие ударных.
        case percussionOnly
        /// Ударные + отделение солирующей партии.
        case full
    }

    // Окно 93 мс с шагом 23 мс: достаточно частотного разрешения для гармоник и
    // достаточно временного, чтобы не размазать удары.
    static let fftSize = 2048
    static let hop = 512

    /// Полуширина медианных окон HPSS: 9 кадров ≈ 0.2 с, 17 бинов ≈ 180 Гц.
    private static let timeMedianWidth = 9
    private static let frequencyMedianWidth = 17

    /// Сколько похожих кадров усредняется в модель повторяющегося фона.
    /// 24 подобрано перебором на тестовых записях: меньше — модель фона шумит и режет
    /// гармонию, больше — в медиану попадают куски других частей песни. Настраивается,
    /// подбор идёт через Tools/DSPCheck.
    static var similarFrames = 24
    /// Показатель степени для маски: <1 делает вырезание мягче, сохраняя больше энергии.
    static var maskExponent: Float = 1
    /// Нижняя граница маски аккомпанемента — страховка от полного зануления гармонии.
    static var maskFloor: Float = 0
    /// Похожий кадр должен быть хотя бы в секунде отсюда, иначе «повтором»
    /// окажется соседний кадр той же самой ноты.
    private static let minSeparationSeconds = 1.0

    static func separate(samples: [Float], sampleRate: Double, mode: Mode = .full) -> Separated {
        guard samples.count > fftSize * 2 else {
            return Separated(accompaniment: samples, melody: [])
        }

        let stft = STFT(size: fftSize, hop: hop)
        let spectrum = stft.forward(samples)
        let magnitude = spectrum.magnitudes()
        let frames = spectrum.frameCount
        let bins = spectrum.binCount

        // --- Шаг 1: HPSS ---
        let harmonicEstimate = medianAlongTime(magnitude, frames: frames, bins: bins, width: timeMedianWidth)
        let percussiveEstimate = medianAlongFrequency(magnitude, frames: frames, bins: bins, width: frequencyMedianWidth)

        var harmonicMask = [Float](repeating: 0, count: magnitude.count)
        for i in 0..<magnitude.count {
            let h = harmonicEstimate[i] * harmonicEstimate[i]
            let p = percussiveEstimate[i] * percussiveEstimate[i]
            harmonicMask[i] = h + p > 1e-12 ? h / (h + p) : 0
        }

        var harmonicMagnitude = [Float](repeating: 0, count: magnitude.count)
        vDSP_vmul(magnitude, 1, harmonicMask, 1, &harmonicMagnitude, 1, vDSP_Length(magnitude.count))

        guard mode == .full else {
            return Separated(
                accompaniment: stft.inverse(spectrum, mask: harmonicMask, length: samples.count),
                melody: []
            )
        }

        // --- Шаг 2: REPET-SIM ---
        let repeating = repeatingModel(
            magnitude: harmonicMagnitude, frames: frames, bins: bins, sampleRate: sampleRate
        )

        var accompanimentMask = [Float](repeating: 0, count: magnitude.count)
        var melodyMask = [Float](repeating: 0, count: magnitude.count)
        for i in 0..<magnitude.count {
            let observed = harmonicMagnitude[i]
            guard observed > 1e-9 else { continue }
            // Фон не может быть громче наблюдаемого — иначе маска усилит то, чего нет.
            let background = min(repeating[i], observed)
            var share = background / observed
            if maskExponent != 1 { share = powf(share, maskExponent) }
            share = max(maskFloor, min(1, share))
            accompanimentMask[i] = harmonicMask[i] * share
            melodyMask[i] = harmonicMask[i] * (1 - share)
        }

        return Separated(
            accompaniment: stft.inverse(spectrum, mask: accompanimentMask, length: samples.count),
            melody: stft.inverse(spectrum, mask: melodyMask, length: samples.count)
        )
    }

    // MARK: - Повторяющийся фон

    /// Для каждого кадра — медиана по нескольким наиболее похожим кадрам записи.
    private static func repeatingModel(
        magnitude: [Float], frames: Int, bins: Int, sampleRate: Double
    ) -> [Float] {
        var model = magnitude
        guard frames > 4 else { return model }

        let features = similarityFeatures(magnitude: magnitude, frames: frames, bins: bins)
        let featureCount = features.count / frames
        let minSeparation = max(1, Int(minSeparationSeconds * sampleRate / Double(hop)))

        var similarity = [Float](repeating: 0, count: frames)
        var chosen = [Int](repeating: 0, count: similarFrames)
        var chosenScore = [Float](repeating: 0, count: similarFrames)
        var window = [Float](repeating: 0, count: similarFrames)

        for frame in 0..<frames {
            // Косинусная близость ко всем кадрам сразу: признаки уже нормированы,
            // поэтому это обычное умножение матрицы на вектор.
            features.withUnsafeBufferPointer { f in
                similarity.withUnsafeMutableBufferPointer { out in
                    vDSP_mmul(
                        f.baseAddress!, 1,
                        f.baseAddress! + frame * featureCount, 1,
                        out.baseAddress!, 1,
                        vDSP_Length(frames), 1, vDSP_Length(featureCount)
                    )
                }
            }

            // Отбор лучших кадров без единой аллокации: этот цикл выполняется
            // frames × frames раз, любая временная коллекция здесь стоит секунд.
            var count = 0
            var worstIndex = 0
            var worst: Float = 0
            for candidate in 0..<frames where abs(candidate - frame) >= minSeparation {
                let score = similarity[candidate]
                if count < similarFrames {
                    chosen[count] = candidate
                    chosenScore[count] = score
                    if count == 0 || score < worst {
                        worst = score
                        worstIndex = count
                    }
                    count += 1
                } else if score > worst {
                    chosen[worstIndex] = candidate
                    chosenScore[worstIndex] = score
                    worst = chosenScore[0]
                    worstIndex = 0
                    for k in 1..<count where chosenScore[k] < worst {
                        worst = chosenScore[k]
                        worstIndex = k
                    }
                }
            }
            // Повторов не нашлось — фоном считаем сам кадр, разделение его не тронет.
            guard count > 0 else { continue }

            let base = frame * bins
            for bin in 0..<bins {
                for k in 0..<count { window[k] = magnitude[chosen[k] * bins + bin] }
                model[base + bin] = median(&window, count: count)
            }
        }
        return model
    }

    /// Сжатая и нормированная спектрограмма — по ней сравниваются кадры.
    /// Полный спектр для этого избыточен: важен общий тембр, а не отдельные бины.
    private static func similarityFeatures(magnitude: [Float], frames: Int, bins: Int) -> [Float] {
        let bandCount = 40
        var edges = [Int](repeating: 0, count: bandCount + 1)
        for i in 0...bandCount {
            let position = Double(i) / Double(bandCount)
            // Логарифмическая шкала: низ важнее, там лежат основные тоны аккордов.
            edges[i] = min(bins - 1, Int(Double(bins - 1) * pow(position, 2.2)))
        }

        var features = [Float](repeating: 0, count: frames * bandCount)
        for frame in 0..<frames {
            let base = frame * bins
            var norm: Float = 0
            for band in 0..<bandCount {
                let lower = edges[band]
                let upper = max(lower + 1, edges[band + 1])
                var sum: Float = 0
                for bin in lower..<min(upper, bins) { sum += magnitude[base + bin] }
                let value = log1pf(sum)
                features[frame * bandCount + band] = value
                norm += value * value
            }
            norm = sqrt(norm)
            guard norm > 1e-9 else { continue }
            for band in 0..<bandCount { features[frame * bandCount + band] /= norm }
        }
        return features
    }

    // MARK: - Медианные фильтры

    private static func medianAlongTime(
        _ values: [Float], frames: Int, bins: Int, width: Int
    ) -> [Float] {
        var result = values
        let half = width / 2
        var window = [Float](repeating: 0, count: width)
        for bin in 0..<bins {
            for frame in 0..<frames {
                let lower = max(0, frame - half)
                let upper = min(frames - 1, frame + half)
                var count = 0
                for f in lower...upper {
                    window[count] = values[f * bins + bin]
                    count += 1
                }
                result[frame * bins + bin] = median(&window, count: count)
            }
        }
        return result
    }

    private static func medianAlongFrequency(
        _ values: [Float], frames: Int, bins: Int, width: Int
    ) -> [Float] {
        var result = values
        let half = width / 2
        var window = [Float](repeating: 0, count: width)
        for frame in 0..<frames {
            let base = frame * bins
            for bin in 0..<bins {
                let lower = max(0, bin - half)
                let upper = min(bins - 1, bin + half)
                var count = 0
                for b in lower...upper {
                    window[count] = values[base + b]
                    count += 1
                }
                result[base + bin] = median(&window, count: count)
            }
        }
        return result
    }

    /// Медиана через quickselect: полная сортировка окна не нужна, а на окнах в два-три
    /// десятка элементов разница с вставками уже в разы — этот вызов делается миллионы раз.
    @inline(__always)
    private static func median(_ window: inout [Float], count: Int) -> Float {
        guard count > 0 else { return 0 }
        guard count > 1 else { return window[0] }
        return window.withUnsafeMutableBufferPointer { buffer in
            let middle = count / 2
            var value = select(buffer, count: count, k: middle)
            if count % 2 == 0 {
                // Для чётного окна нужен ещё и предыдущий по порядку элемент; после
                // select всё, что левее середины, уже не больше найденного.
                var lower = buffer[0]
                for i in 1..<middle where buffer[i] > lower { lower = buffer[i] }
                value = (value + lower) / 2
            }
            return value
        }
    }

    /// k-я порядковая статистика на месте (алгоритм Хоара).
    @inline(__always)
    private static func select(_ buffer: UnsafeMutableBufferPointer<Float>, count: Int, k: Int) -> Float {
        var low = 0
        var high = count - 1
        while low < high {
            let pivot = buffer[(low + high) / 2]
            var i = low
            var j = high
            while i <= j {
                while buffer[i] < pivot { i += 1 }
                while buffer[j] > pivot { j -= 1 }
                if i <= j {
                    buffer.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j { high = j } else if k >= i { low = i } else { break }
        }
        return buffer[k]
    }
}
