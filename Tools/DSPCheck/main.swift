import AVFoundation
import Foundation

// Прогон DSP-конвейера в консоли.
//   ./Tools/DSPCheck/run.sh              — синтетический фрагмент C — Am — F — G
//   ./Tools/DSPCheck/run.sh запись.caf   — реальный файл с диагностикой хромы

let sampleRate = 22050.0

func loadAudio(path: String) -> [Float]? {
    let url = URL(fileURLWithPath: path)
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let sourceFormat = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                        frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
    try? file.read(into: buffer)

    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                     channels: 1, interleaved: false) else { return nil }
    if abs(sourceFormat.sampleRate - sampleRate) < 1, sourceFormat.channelCount == 1,
       let data = buffer.floatChannelData?[0] {
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: target),
          let output = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / sourceFormat.sampleRate) + 1024
          ) else { return nil }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
    guard let data = output.floatChannelData?[0] else { return nil }
    return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
}

let arguments = CommandLine.arguments.dropFirst()
let mode = arguments.first ?? "clean"
let isSynthetic = mode == "clean" || mode == "noisy"
let samples: [Float]

switch mode {
case "clean":
    samples = DemoSignal.make(sampleRate: sampleRate)
    print("=== Синтетический тест (чистый) ===")
    print("Ожидается: BPM 120, тональность C, аккорды C → Am → F → G")
case "noisy":
    samples = DemoSignal.makeNoisy(sampleRate: sampleRate)
    print("=== Синтетический тест (как из микрофона) ===")
    print("Ожидается: BPM 120, тональность C, аккорды C → Am → F → G")
default:
    guard let loaded = loadAudio(path: mode) else {
        print("Не удалось прочитать \(mode)")
        exit(1)
    }
    samples = loaded
    print("=== Файл: \(mode) ===")
}

var peak: Float = 0
var sumOfSquares: Float = 0
for value in samples {
    peak = max(peak, abs(value))
    sumOfSquares += value * value
}
let rms = sqrt(sumOfSquares / Float(max(1, samples.count)))
print(String(format: "Сэмплов: %d (%.2f с), пик %.3f, RMS %.4f (%.1f дБ)",
             samples.count, Double(samples.count) / sampleRate, peak, rms, 20 * log10(max(rms, 1e-9))))

var chordOptions = ChordRecognizer.Options.beatSynchronous
if let penalty = ProcessInfo.processInfo.environment["PENALTY"].flatMap(Float.init) {
    chordOptions.changePenalty = penalty
    print("Штраф за смену аккорда: \(penalty)")
}
let result = SongAnalyzer.analyze(samples: samples, sampleRate: sampleRate, chordOptions: chordOptions)

print("")
print(String(format: "BPM: %.1f (уверенность %.2f)", result.bpm, result.tempoConfidence))
print("Тональность: \(result.key ?? "—")")
print("Долей: \(result.beats.count), тактов: \(result.bars.count), сильная доля: \(result.downbeatOffset)")
print("")
print("Аккорды:")
for segment in result.chords {
    print(String(format: "  %5.2f – %5.2f  %-6@  (%.2f)",
                 segment.start, segment.end, segment.label.name as NSString, segment.confidence))
}
print("Прогрессия: \(result.progressionSummary)")

// MARK: - Диагностика хромы

let chroma = ChromaExtractor.chromagram(samples: samples, sampleRate: sampleRate)
print("")
print("--- Хрома: \(chroma.count) кадров ---")
var average = [Float](repeating: 0, count: 12)
for frame in chroma {
    for i in 0..<12 { average[i] += frame.values[i] / Float(chroma.count) }
}
print("Средняя хрома: " + zip(ChordLabel.pitchNames, average)
    .map { String(format: "%@ %.2f", $0.0, $0.1) }.joined(separator: "  "))

let energies = chroma.map { $0.energy }.sorted()
print(String(format: "Энергия кадров: мин %.3f, медиана %.3f, макс %.3f",
             energies.first ?? 0, energies[energies.count / 2], energies.last ?? 0))

// Насколько уверенно лучший аккорд обходит порог «нет аккорда».
let noChordScore = ChordRecognizer.Options.default.noChordScore
var wins = 0
var margins: [Float] = []
for frame in chroma {
    let best = ChordRecognizer.scores(for: frame.values).max() ?? 0
    margins.append(best - noChordScore)
    if best > noChordScore { wins += 1 }
}
let sortedMargins = margins.sorted()
print(String(format: "Аккорд проходит порог %.2f в %d из %d кадров; запас: медиана %.3f, макс %.3f",
             noChordScore, wins, chroma.count, sortedMargins[sortedMargins.count / 2], sortedMargins.last ?? 0))

print("")
print("Кадры (каждый пятый):")
for frame in stride(from: 0, to: chroma.count, by: 5).map({ chroma[$0] }).prefix(16) {
    let scores = ChordRecognizer.scores(for: frame.values)
    var bestIndex = 0
    for (i, value) in scores.enumerated() where value > scores[bestIndex] { bestIndex = i }
    let winner = ChordRecognizer.bestLabel(for: frame.values)
    print(String(format: "  t=%5.2f  победитель %-6@   лучший аккорд %-6@ (%.2f)   энергия %.3f",
                 frame.time,
                 winner.label.name as NSString,
                 ChordRecognizer.templates[bestIndex].label.name as NSString, scores[bestIndex],
                 frame.energy))
}

if isSynthetic {
    var failures: [String] = []
    if abs(result.bpm - 120) > 3 { failures.append("BPM \(result.bpm) вместо ~120") }
    var unique: [String] = []
    for segment in result.chords where !segment.label.isNone {
        if unique.last != segment.label.name { unique.append(segment.label.name) }
    }
    for (index, root) in ["C", "A", "F", "G"].enumerated() where index < unique.count {
        if !unique[index].hasPrefix(root) {
            failures.append("аккорд \(index + 1): \(unique[index]) вместо \(root)…")
        }
    }
    if unique.count != 4 { failures.append("сегментов: \(unique.count) вместо 4 (\(unique.joined(separator: ", ")))") }
    print("")
    print(failures.isEmpty ? "РЕЗУЛЬТАТ: OK" : "РЕЗУЛЬТАТ: расхождения — " + failures.joined(separator: "; "))
}
