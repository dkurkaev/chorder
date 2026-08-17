import Foundation

/// Синтезированный фрагмент (C — Am — F — G, 120 BPM) — чтобы проверять конвейер
/// без микрофона: на симуляторе его нет, а на устройстве бывает шумно.
enum DemoSignal {
    static func make(sampleRate: Double, bpm: Double = 120, duration: Double = 8) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(duration * sampleRate))
        let beatDuration = 60.0 / bpm
        let progression: [[Int]] = [
            [48, 60, 64, 67],   // C
            [45, 57, 60, 64],   // Am
            [41, 53, 57, 60],   // F
            [43, 55, 59, 62]    // G
        ]
        var seed: UInt64 = 42
        let chordDuration = duration / Double(progression.count)

        var beatIndex = 0
        while Double(beatIndex) * beatDuration < duration {
            let time = Double(beatIndex) * beatDuration
            let chord = progression[min(progression.count - 1, Int(time / chordDuration))]
            for midi in chord {
                addNote(&samples, sampleRate: sampleRate, midi: midi,
                        start: time, duration: beatDuration * 1.1, amplitude: 0.12)
            }
            addClick(&samples, sampleRate: sampleRate, at: time,
                     amplitude: beatIndex % 4 == 0 ? 0.5 : 0.28, seed: &seed)
            beatIndex += 1
        }
        return samples
    }

    /// Тот же фрагмент, но «как из микрофона»: шум комнаты, полоса динамика и лёгкое эхо.
    static func makeNoisy(sampleRate: Double, bpm: Double = 120, duration: Double = 8,
                          noiseLevel: Double = 0.02) -> [Float] {
        var samples = make(sampleRate: sampleRate, bpm: bpm, duration: duration)
        var seed: UInt64 = 1337

        // Розоватый шум: белый шум, пропущенный через однополюсный фильтр.
        var noiseState: Double = 0
        for i in 0..<samples.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let white = Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1.0
            noiseState = noiseState * 0.92 + white * 0.08
            samples[i] += Float(noiseState * noiseLevel * 12)
        }

        // Комнатное эхо: одна ранняя отражённая копия.
        let delay = Int(0.037 * sampleRate)
        for i in stride(from: samples.count - 1, through: delay, by: -1) {
            samples[i] += samples[i - delay] * 0.25
        }

        // Полоса пропускания примерно как у телефонного микрофона: 120 Гц … 7 кГц.
        highPass(&samples, cutoff: 120, sampleRate: sampleRate)
        lowPass(&samples, cutoff: 7000, sampleRate: sampleRate)
        return samples
    }

    private static func highPass(_ samples: inout [Float], cutoff: Double, sampleRate: Double) {
        let rc = 1.0 / (2 * .pi * cutoff)
        let dt = 1.0 / sampleRate
        let alpha = Float(rc / (rc + dt))
        var previousInput: Float = 0
        var previousOutput: Float = 0
        for i in 0..<samples.count {
            let input = samples[i]
            let output = alpha * (previousOutput + input - previousInput)
            samples[i] = output
            previousInput = input
            previousOutput = output
        }
    }

    private static func lowPass(_ samples: inout [Float], cutoff: Double, sampleRate: Double) {
        let rc = 1.0 / (2 * .pi * cutoff)
        let dt = 1.0 / sampleRate
        let alpha = Float(dt / (rc + dt))
        var previous: Float = 0
        for i in 0..<samples.count {
            previous += alpha * (samples[i] - previous)
            samples[i] = previous
        }
    }

    private static func addNote(_ buffer: inout [Float], sampleRate: Double, midi: Int,
                                start: Double, duration: Double, amplitude: Double) {
        let startIndex = Int(start * sampleRate)
        let count = Int(duration * sampleRate)
        let frequency = 440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
        for i in 0..<count {
            let index = startIndex + i
            guard index >= 0 && index < buffer.count else { continue }
            let t = Double(i) / sampleRate
            let envelope = exp(-3.0 * t / max(0.05, duration))
            var value = 0.0
            for harmonic in 1...4 {
                value += sin(2 * .pi * frequency * Double(harmonic) * t) / Double(harmonic)
            }
            buffer[index] += Float(value * envelope * amplitude)
        }
    }

    private static func addClick(_ buffer: inout [Float], sampleRate: Double, at time: Double,
                                 amplitude: Double, seed: inout UInt64) {
        let startIndex = Int(time * sampleRate)
        let count = Int(0.05 * sampleRate)
        for i in 0..<count {
            let index = startIndex + i
            guard index >= 0 && index < buffer.count else { continue }
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(Int64(bitPattern: seed >> 11)) / Double(1 << 52) - 1.0
            let envelope = exp(-40.0 * Double(i) / sampleRate)
            buffer[index] += Float(noise * envelope * amplitude)
        }
    }
}
