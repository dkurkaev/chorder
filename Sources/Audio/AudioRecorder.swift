import AVFoundation
import Combine
import Foundation

/// Захват звука с микрофона: ресемпл в 22.05 кГц моно, накопление сэмплов,
/// уровень для индикатора и «живой» разбор последних секунд.
final class AudioRecorder: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case analyzing
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0          // 0…1, сглаженный RMS
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var liveChord: ChordLabel = .none
    @Published private(set) var liveConfidence: Float = 0
    @Published private(set) var liveBPM: Double = 0
    /// Уровни частотных полос (0…1) для визуализации, снизу вверх по частоте.
    @Published private(set) var spectrum: [Float] = Array(repeating: 0, count: AudioRecorder.bandCount)
    /// Текущая хрома (12 классов высоты, 0…1) — подсветка нот аккорда.
    @Published private(set) var chroma: [Float] = Array(repeating: 0, count: 12)

    static let bandCount = 40

    static let sampleRate: Double = 22050
    /// Дольше 60 с прототипу не нужно — и память, и время анализа под контролем.
    static let maxDuration: Double = 60

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    private let lock = NSLock()
    private var samples: [Float] = []

    // Визуализация спектра: считается прямо на аудио-потоке по короткому окну.
    private static let visualFFTSize = 2048
    private let visualFFT = FFTProcessor(size: AudioRecorder.visualFFTSize)
    private lazy var bands: [(low: Int, high: Int)] = Self.makeBands(
        fftSize: Self.visualFFTSize, sampleRate: Self.sampleRate, count: Self.bandCount
    )
    private var smoothedBands = [Float](repeating: 0, count: AudioRecorder.bandCount)
    private var smoothedChroma = [Float](repeating: 0, count: 12)
    private var lastVisualUpdate: CFAbsoluteTime = 0

    private let analysisQueue = DispatchQueue(label: "com.chorder.analysis", qos: .userInitiated)
    private var liveTimer: Timer?
    private var isLiveAnalysisRunning = false

    var isRecording: Bool { state == .recording }

    // MARK: - Разрешение на микрофон

    func requestPermission(completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    // MARK: - Запись

    func start() {
        guard state != .recording else { return }
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.state = .denied
                return
            }
            do {
                try self.startEngine()
                self.state = .recording
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        // Без Bluetooth-опций: HFP-микрофон даёт 8 кГц, для разбора гармонии это бесполезно.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.sampleRate * Self.maxDuration))
        lock.unlock()

        elapsed = 0
        spectrum = [Float](repeating: 0, count: Self.bandCount)
        chroma = [Float](repeating: 0, count: 12)
        smoothedBands = [Float](repeating: 0, count: Self.bandCount)
        smoothedChroma = [Float](repeating: 0, count: 12)
        liveChord = .none
        liveBPM = 0
        liveConfidence = 0

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "Chorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, inputFormat: inputFormat)
        }

        engine.prepare()
        try engine.start()
        startLiveAnalysis()
    }

    private func process(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }

        let count = Int(output.frameLength)
        let chunk = UnsafeBufferPointer(start: channel, count: count)

        var sumOfSquares: Float = 0
        for value in chunk { sumOfSquares += value * value }
        let rms = sqrt(sumOfSquares / Float(count))

        lock.lock()
        let overflow = samples.count >= Int(Self.sampleRate * Self.maxDuration)
        if !overflow { samples.append(contentsOf: chunk) }
        let total = samples.count
        let visualWindow: [Float] = total >= Self.visualFFTSize
            ? Array(samples[(total - Self.visualFFTSize)..<total])
            : []
        lock.unlock()

        updateVisualization(window: visualWindow)

        let seconds = Double(total) / Self.sampleRate
        // Логарифмическая шкала: -50 дБ … 0 дБ → 0 … 1
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = min(1, max(0, (db + 50) / 50))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.level += (normalized - self.level) * 0.35
            self.elapsed = seconds
            if overflow && self.state == .recording {
                self.finishRecordingIfNeeded()
            }
        }
    }

    private func finishRecordingIfNeeded() {
        guard state == .recording else { return }
        onMaxDurationReached?()
    }

    /// Вызывается, когда достигнут лимит длительности — экран сам решает, что делать.
    var onMaxDurationReached: (() -> Void)?

    // MARK: - Визуализация

    /// Полосы с логарифмическим шагом от 60 Гц до 8 кГц — примерно как слышит ухо.
    private static func makeBands(fftSize: Int, sampleRate: Double, count: Int) -> [(low: Int, high: Int)] {
        let binHz = sampleRate / Double(fftSize)
        let maxBin = fftSize / 2 - 1
        let lowFrequency = 60.0
        let highFrequency = min(8000.0, sampleRate / 2 - binHz)
        var result: [(low: Int, high: Int)] = []
        for i in 0..<count {
            let from = lowFrequency * pow(highFrequency / lowFrequency, Double(i) / Double(count))
            let to = lowFrequency * pow(highFrequency / lowFrequency, Double(i + 1) / Double(count))
            var low = max(1, Int(from / binHz))
            var high = min(maxBin, Int(to / binHz))
            if high < low { high = low }
            low = min(low, maxBin)
            result.append((low, high))
        }
        return result
    }

    private func updateVisualization(window: [Float]) {
        guard !window.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastVisualUpdate > 1.0 / 24 else { return }
        lastVisualUpdate = now

        let spectrum = visualFFT.magnitudes(window[0..<window.count])

        var levels = [Float](repeating: 0, count: bands.count)
        for (index, band) in bands.enumerated() {
            var peak: Float = 0
            for bin in band.low...band.high { peak = max(peak, spectrum[bin]) }
            // Логарифмическая шкала: разброс амплитуд огромный, линейная выглядит мёртвой.
            let level = min(1, log10f(1 + 400 * peak) / 1.6)
            // Быстрая атака, мягкий спад — так столбики «дышат», а не мигают.
            let previous = smoothedBands[index]
            levels[index] = level > previous ? level : previous * 0.82 + level * 0.18
        }
        smoothedBands = levels

        var chromaValues = [Float](repeating: 0, count: 12)
        let binHz = Self.sampleRate / Double(Self.visualFFTSize)
        for bin in 1..<spectrum.count {
            let frequency = Double(bin) * binHz
            guard frequency >= 65, frequency <= 2100 else { continue }
            let midi = 69 + 12 * log2(frequency / 440)
            let pitchClass = ((Int(midi.rounded()) % 12) + 12) % 12
            chromaValues[pitchClass] += spectrum[bin]
        }
        let chromaPeak = chromaValues.max() ?? 0
        if chromaPeak > 0 {
            for i in 0..<12 { chromaValues[i] = min(1, chromaValues[i] / chromaPeak) }
        }
        for i in 0..<12 {
            smoothedChroma[i] = chromaValues[i] > smoothedChroma[i]
                ? chromaValues[i]
                : smoothedChroma[i] * 0.8 + chromaValues[i] * 0.2
        }

        let publishedSpectrum = smoothedBands
        let publishedChroma = smoothedChroma
        DispatchQueue.main.async { [weak self] in
            self?.spectrum = publishedSpectrum
            self?.chroma = publishedChroma
        }
    }

    // MARK: - Живой разбор

    private func startLiveAnalysis() {
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.runLiveAnalysis()
        }
    }

    private func runLiveAnalysis() {
        guard !isLiveAnalysisRunning else { return }
        let window = Int(Self.sampleRate * 5)
        lock.lock()
        let snapshot = Array(samples.suffix(window))
        lock.unlock()
        guard snapshot.count > Int(Self.sampleRate) else { return }

        isLiveAnalysisRunning = true
        analysisQueue.async { [weak self] in
            guard let self else { return }
            let result = SongAnalyzer.quickAnalyze(samples: snapshot, sampleRate: Self.sampleRate)
            DispatchQueue.main.async {
                self.liveChord = result.chord
                self.liveConfidence = result.confidence
                if result.bpm > 0 { self.liveBPM = result.bpm }
                self.isLiveAnalysisRunning = false
            }
        }
    }

    // MARK: - Остановка и разбор

    /// Останавливает запись, сохраняет аудио и возвращает полный разбор.
    func stopAndAnalyze(completion: @escaping (AnalysisResult, URL?) -> Void) {
        liveTimer?.invalidate()
        liveTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        lock.lock()
        let captured = samples
        lock.unlock()

        state = .analyzing
        level = 0

        analysisQueue.async { [weak self] in
            let result = SongAnalyzer.analyze(samples: captured, sampleRate: Self.sampleRate)
            let url = AudioFileStore.shared.write(samples: captured, sampleRate: Self.sampleRate)
            DispatchQueue.main.async {
                self?.state = .idle
                completion(result, url)
            }
        }
    }

    func cancel() {
        liveTimer?.invalidate()
        liveTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        state = .idle
        level = 0
        elapsed = 0
        spectrum = [Float](repeating: 0, count: Self.bandCount)
        chroma = [Float](repeating: 0, count: 12)
    }
}
