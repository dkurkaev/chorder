import Accelerate
import Foundation

/// Обёртка над vDSP real-FFT: окно Ханна + амплитудный спектр.
/// Не потокобезопасен — по одному экземпляру на поток анализа.
final class FFTProcessor {
    let size: Int
    let binCount: Int

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>

    init(size: Int) {
        precondition(size > 0 && size.nonzeroBitCount == 1, "FFT size должен быть степенью двойки")
        self.size = size
        self.binCount = size / 2
        self.log2n = vDSP_Length(log2(Double(size)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Не удалось создать FFT setup")
        }
        self.setup = setup

        window = .allocate(capacity: size)
        windowed = .allocate(capacity: size)
        realp = .allocate(capacity: binCount)
        imagp = .allocate(capacity: binCount)

        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        windowed.initialize(repeating: 0, count: size)
        realp.initialize(repeating: 0, count: binCount)
        imagp.initialize(repeating: 0, count: binCount)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        windowed.deallocate()
        realp.deallocate()
        imagp.deallocate()
    }

    /// Амплитудный спектр кадра. Кадр короче `size` дополняется нулями.
    /// - Returns: массив из `size/2` значений, bin `k` соответствует частоте `k * sampleRate / size`.
    func magnitudes(_ frame: ArraySlice<Float>) -> [Float] {
        var output = [Float](repeating: 0, count: binCount)
        output.withUnsafeMutableBufferPointer { buffer in
            self.magnitudes(frame, into: buffer.baseAddress!)
        }
        return output
    }

    /// Версия без аллокаций — пишет `size/2` значений в `output`.
    func magnitudes(_ frame: ArraySlice<Float>, into output: UnsafeMutablePointer<Float>) {
        let n = min(frame.count, size)
        frame.withUnsafeBufferPointer { src in
            windowed.update(from: src.baseAddress!, count: n)
        }
        if n < size {
            (windowed + n).update(repeating: 0, count: size - n)
        }

        vDSP_vmul(windowed, 1, window, 1, windowed, 1, vDSP_Length(size))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: binCount) { interleaved in
            vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(binCount))
        }

        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        // zrip упаковывает Nyquist в imagp[0]; для наших задач bin 0 всё равно не используется.
        imagp[0] = 0
        vDSP_zvabs(&split, 1, output, 1, vDSP_Length(binCount))

        var scale = 1.0 / (2.0 * Float(size))
        vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(binCount))
    }
}
