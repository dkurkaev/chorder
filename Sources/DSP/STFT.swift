import Accelerate
import Foundation

/// Кратковременное преобразование Фурье с сохранением фазы и обратным синтезом.
///
/// `FFTProcessor` отдаёт только амплитуды — этого хватает для хромы и онсетов, но не для
/// разделения источников: чтобы собрать сигнал обратно, нужна фаза. Здесь спектр хранится
/// целиком, а `inverse` возвращает звук методом overlap-add.
final class STFT {
    let size: Int
    let hop: Int
    /// Бины 0…size/2 включительно (последний — Найквист).
    let binCount: Int

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]

    init(size: Int = 2048, hop: Int = 512) {
        precondition(size.nonzeroBitCount == 1, "Размер FFT должен быть степенью двойки")
        precondition(hop > 0 && hop <= size, "Шаг должен укладываться в окно")
        self.size = size
        self.hop = hop
        self.binCount = size / 2 + 1
        self.log2n = vDSP_Length(log2(Double(size)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Не удалось создать FFT setup")
        }
        self.setup = setup

        var hann = [Float](repeating: 0, count: size)
        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        self.window = hann
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Комплексная спектрограмма: кадры идут подряд, внутри кадра — `binCount` бинов.
    struct Spectrogram {
        var real: [Float]
        var imag: [Float]
        var frameCount: Int
        var binCount: Int

        @inline(__always)
        func index(frame: Int, bin: Int) -> Int { frame * binCount + bin }

        /// Амплитуды в том же порядке, что и `real`/`imag`.
        func magnitudes() -> [Float] {
            var result = [Float](repeating: 0, count: real.count)
            for i in 0..<real.count {
                result[i] = sqrt(real[i] * real[i] + imag[i] * imag[i])
            }
            return result
        }
    }

    func forward(_ samples: [Float]) -> Spectrogram {
        let frameCount = max(1, Int(ceil(Double(max(0, samples.count)) / Double(hop))))
        var real = [Float](repeating: 0, count: frameCount * binCount)
        var imag = [Float](repeating: 0, count: frameCount * binCount)

        var windowed = [Float](repeating: 0, count: size)
        var realp = [Float](repeating: 0, count: size / 2)
        var imagp = [Float](repeating: 0, count: size / 2)

        for frame in 0..<frameCount {
            let start = frame * hop
            let available = max(0, min(size, samples.count - start))
            if available > 0 {
                samples.withUnsafeBufferPointer { src in
                    windowed.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress!.update(from: src.baseAddress! + start, count: available)
                    }
                }
            }
            if available < size {
                windowed.withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + available).update(repeating: 0, count: size - available)
                }
            }
            vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(size))

            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { buf in
                        buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { interleaved in
                            vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }

            // zrip упаковывает Найквист в imagp[0]; разворачиваем в честные бины 0 и size/2.
            let base = frame * binCount
            let dc = realp[0]
            let nyquist = imagp[0]
            real[base] = dc
            imag[base] = 0
            for bin in 1..<(size / 2) {
                real[base + bin] = realp[bin]
                imag[base + bin] = imagp[bin]
            }
            real[base + size / 2] = nyquist
            imag[base + size / 2] = 0
        }

        return Spectrogram(real: real, imag: imag, frameCount: frameCount, binCount: binCount)
    }

    /// Обратный синтез. Окно применяется второй раз (анализ + синтез), поэтому
    /// перекрытие нормируется накопленной суммой квадратов окна — так шов не слышен
    /// при любом шаге, не только при идеальном COLA.
    func inverse(_ spectrum: Spectrogram, length: Int) -> [Float] {
        let total = max(length, (spectrum.frameCount - 1) * hop + size)
        var output = [Float](repeating: 0, count: total)
        var normalization = [Float](repeating: 0, count: total)

        var realp = [Float](repeating: 0, count: size / 2)
        var imagp = [Float](repeating: 0, count: size / 2)
        var frame = [Float](repeating: 0, count: size)
        let scale = 1.0 / (2.0 * Float(size))

        for index in 0..<spectrum.frameCount {
            let base = index * binCount
            realp[0] = spectrum.real[base]
            imagp[0] = spectrum.real[base + size / 2]     // Найквист обратно в imagp[0]
            for bin in 1..<(size / 2) {
                realp[bin] = spectrum.real[base + bin]
                imagp[bin] = spectrum.imag[base + bin]
            }

            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    frame.withUnsafeMutableBufferPointer { buf in
                        buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { interleaved in
                            vDSP_ztoc(&split, 1, interleaved, 2, vDSP_Length(size / 2))
                        }
                    }
                }
            }
            vDSP_vsmul(frame, 1, [scale], &frame, 1, vDSP_Length(size))

            let start = index * hop
            let count = min(size, total - start)
            guard count > 0 else { continue }
            for i in 0..<count {
                let w = window[i]
                output[start + i] += frame[i] * w
                normalization[start + i] += w * w
            }
        }

        for i in 0..<total where normalization[i] > 1e-6 {
            output[i] /= normalization[i]
        }
        if output.count > length { output.removeLast(output.count - length) }
        return output
    }

    /// Собирает сигнал по маске, наложенной на исходный спектр (фаза берётся оттуда же).
    func inverse(_ spectrum: Spectrogram, mask: [Float], length: Int) -> [Float] {
        var masked = spectrum
        for i in 0..<masked.real.count {
            masked.real[i] *= mask[i]
            masked.imag[i] *= mask[i]
        }
        return inverse(masked, length: length)
    }
}
