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
var samples: [Float]

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

// LIMIT=60 — обрезать так же, как это делает приложение при импорте файла.
if let limit = ProcessInfo.processInfo.environment["LIMIT"].flatMap(Double.init) {
    let frames = Int(limit * sampleRate)
    if samples.count > frames {
        samples = Array(samples.prefix(frames))
        print(String(format: "Обрезано до %.0f с", limit))
    }
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

// TRACKS=1 — сохранить обе дорожки рядом с исходником, чтобы послушать.
// SEPARATE=0 — без разделения, =p — только снять ударные, иначе полный разбор.
let separationMode: SourceSeparator.Mode?
switch ProcessInfo.processInfo.environment["SEPARATE"] {
case "0": separationMode = nil; print("Режим: без разделения")
case "p": separationMode = .percussionOnly; print("Режим: только снятие ударных")
default: separationMode = .full; print("Режим: ударные + отделение мелодии")
}

// Подбор параметров разделения: REPET_K / REPET_EXP / REPET_FLOOR.
let env = ProcessInfo.processInfo.environment
if let k = env["REPET_K"].flatMap(Int.init) { SourceSeparator.similarFrames = k }
if let e = env["REPET_EXP"].flatMap(Float.init) { SourceSeparator.maskExponent = e }
if let f = env["REPET_FLOOR"].flatMap(Float.init) { SourceSeparator.maskFloor = f }
if let p = env["VOCAB_PEN"].flatMap(Float.init) { SongAnalyzer.outsidePenalty = p }
if let r = env["TRANS_RELIEF"].flatMap(Float.init) { SongAnalyzer.transitionRelief = r }
if let a = env["VOCAB_ADV"].flatMap(Float.init) { SongAnalyzer.outsideAdvantage = a }
if let b = env["VOCAB_BOOST"].flatMap(Float.init) { SongAnalyzer.vocabularyBoost = b }
if let c = env["SHRINK"].flatMap(Double.init) { PhraseModel.shrinkCost = c }
if let k = env["SKIP"].flatMap(Double.init) { PhraseModel.skipCost = k }
if let u = env["TRANS_UNKNOWN"].flatMap(Float.init) { SongAnalyzer.unknownTransitionFactor = u }

if ProcessInfo.processInfo.environment["TRACKS"] == "1" {
    let started = Date()
    let separated = SourceSeparator.separate(samples: samples, sampleRate: sampleRate)
    print(String(format: "Разделение заняло %.2f с", -started.timeIntervalSinceNow))

    let base = isSynthetic
        ? "\(NSTemporaryDirectory())/\(mode)"
        : URL(fileURLWithPath: mode).deletingPathExtension().path
    for (name, track) in [("accompaniment", separated.accompaniment), ("melody", separated.melody)] {
        let url = URL(fileURLWithPath: "\(base)-\(name).caf")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(track.count)) else { continue }
        buffer.frameLength = AVAudioFrameCount(track.count)
        track.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: track.count)
        }
        try? file.write(from: buffer)
        print("Дорожка: \(url.path)")
    }
}

var chordOptions = ChordRecognizer.Options.beatSynchronous
if let penalty = ProcessInfo.processInfo.environment["PENALTY"].flatMap(Float.init) {
    chordOptions.changePenalty = penalty
    print("Штраф за смену аккорда: \(penalty)")
}
let analysisStarted = Date()
let result = SongAnalyzer.analyze(samples: samples, sampleRate: sampleRate,
                                  chordOptions: chordOptions, separation: separationMode,
                                  useReferences: env["ADAPT"] != "0",
                                  useTransitions: env["TRANS"] != "0",
                                  usePhrase: env["PHRASE"] != "0",
                                  diagnostics: { print($0) })
print(String(format: "Анализ занял %.2f с", -analysisStarted.timeIntervalSinceNow))

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
print("Начала проведений (такты): " + result.phraseStarts.map { String($0 + 1) }.joined(separator: ", "))

// Как темп ведёт себя по ходу записи: если он плывёт, средний BPM врёт везде.
if result.beats.count > 4 {
    let intervals = zip(result.beats.dropFirst(), result.beats).map { $0 - $1 }
    let sorted = intervals.sorted()
    print(String(format: "Интервал долей: медиана %.3f с (%.1f BPM), мин %.3f, макс %.3f",
                 sorted[sorted.count / 2], 60 / sorted[sorted.count / 2], sorted.first!, sorted.last!))
    // Проверка октавы: если между нашими долями лежат такие же сильные онсеты,
    // значит настоящий шаг вдвое короче, а мы считаем через одну.
    let (envelope, rate) = BeatTracker.onsetEnvelope(samples: samples, sampleRate: sampleRate)
    func strength(at times: [Double]) -> Double {
        var sum = 0.0
        var count = 0
        for time in times {
            let frame = Int((time * rate).rounded())
            guard frame >= 1, frame < envelope.count - 1 else { continue }
            sum += Double(max(envelope[frame - 1], max(envelope[frame], envelope[frame + 1])))
            count += 1
        }
        return count > 0 ? sum / Double(count) : 0
    }
    let midpoints = zip(result.beats, result.beats.dropFirst()).map { ($0 + $1) / 2 }
    print(String(format: "Сила онсетов: на долях %.3f, посередине между ними %.3f (отношение %.2f)",
                 strength(at: result.beats), strength(at: midpoints),
                 strength(at: midpoints) / max(1e-9, strength(at: result.beats))))

    var line = "Локальный BPM по 8 долям: "
    var index = 0
    while index + 8 <= intervals.count {
        let window = intervals[index..<(index + 8)]
        let mean = window.reduce(0, +) / Double(window.count)
        line += String(format: "%.0f ", 60 / mean)
        index += 8
    }
    print(line)
}

print("")
print("Такты:")
for bar in result.bars {
    let chords = bar.beatChords.map { $0.isNone ? "·" : $0.name }.joined(separator: " ")
    print(String(format: "  %2d  %5.2f – %5.2f  |%@|", bar.index + 1, bar.start, bar.end, chords as NSString))
}
if let first = result.bars.first {
    let labels = SongAnalyzer.beatChords(beats: result.beats, chords: result.chords, duration: result.duration)
    let meaningful = SongAnalyzer.firstMeaningfulBeat(
        beats: result.beats, beatChords: labels, beatsPerBar: result.beatsPerBar,
        envelope: [], rate: 0
    )
    print(String(format: "Первый такт: доля %d, t=%.2f с. Первая осмысленная доля по гармонии: %d (t=%.2f с)",
                 result.downbeatOffset, first.start, meaningful,
                 meaningful < result.beats.count ? result.beats[meaningful] : 0))
    let changes = result.chords.dropFirst().map { $0.start }
    let onGrid = changes.filter { change in
        result.bars.contains { abs($0.start - change) < 0.12 }
    }
    print("Смен аккордов: \(changes.count), из них на границе такта: \(onGrid.count)")

    // Две метрики качества: сколько долей вообще получили аккорд и сколько тактов
    // держатся под одним аккордом. По ним и сравниваем режимы разделения.
    let allBeats = result.bars.flatMap { $0.beatChords }
    let named = allBeats.filter { !$0.isNone }.count
    let steady = result.bars.filter { bar in
        !(bar.beatChords.first?.isNone ?? true) && bar.beatChords.allSatisfy { $0 == bar.beatChords[0] }
    }.count
    // Распределение аккордов по тактам: если песня крутит цикл из четырёх, а один из них
    // почти исчез — значит его съел похожий сосед.
    var perChord: [String: Int] = [:]
    for bar in result.bars {
        guard let first = bar.beatChords.first, !first.isNone,
              bar.beatChords.allSatisfy({ $0 == first }) else { continue }
        perChord[first.name, default: 0] += 1
    }
    print("Такты по аккордам: " + perChord.sorted { $0.value > $1.value }
        .map { "\($0.key)×\($0.value)" }.joined(separator: "  "))

    print(String(format: "СЛИПШИХСЯ ТАКТОВ: %.0f%%", 100 * SongAnalyzer.stickiness(bars: result.bars)))
    print(String(format: "ПОКРЫТИЕ: %d/%d долей с аккордом (%.0f%%); РОВНЫХ ТАКТОВ: %d/%d (%.0f%%)",
                 named, allBeats.count, 100 * Double(named) / Double(max(1, allBeats.count)),
                 steady, result.bars.count, 100 * Double(steady) / Double(max(1, result.bars.count))))
}

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
