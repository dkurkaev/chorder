import AVFoundation
import Combine
import Foundation

/// Захват звука с микрофона: ресемпл в 22.05 кГц моно, накопление сэмплов,
/// уровень для индикатора и «живой» разбор последних секунд.
final class AudioRecorder: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case recording
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0          // 0…1, сглаженный RMS
    @Published private(set) var elapsed: Double = 0
    /// Уровни частотных полос (0…1) для визуализации, по возрастанию частоты.
    @Published private(set) var spectrum: [Float] = Array(repeating: 0, count: AudioRecorder.bandCount)

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
    private var lastVisualUpdate: CFAbsoluteTime = 0

    private let fileQueue = DispatchQueue(label: "com.chorder.recording", qos: .userInitiated)
    private var startRequested = false

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
        startRequested = true
        requestPermission { [weak self] granted in
            guard let self else { return }
            // Кнопку могли отпустить, пока висел системный запрос доступа.
            guard self.startRequested else { return }
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
        smoothedBands = [Float](repeating: 0, count: Self.bandCount)

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

        let publishedSpectrum = smoothedBands
        DispatchQueue.main.async { [weak self] in
            self?.spectrum = publishedSpectrum
        }
    }

    // MARK: - Остановка

    /// Останавливает запись и сохраняет аудио в файл.
    /// Разбор здесь не запускается — им занимается `AnalysisQueue` уже над сохранённой записью.
    func stopAndSave(completion: @escaping (_ samples: [Float], _ url: URL?, _ duration: Double) -> Void) {
        startRequested = false
        stopEngine()

        lock.lock()
        let captured = samples
        lock.unlock()

        level = 0
        elapsed = 0
        spectrum = [Float](repeating: 0, count: Self.bandCount)
        let duration = Double(captured.count) / Self.sampleRate

        fileQueue.async { [weak self] in
            let url = AudioFileStore.shared.write(samples: captured, sampleRate: Self.sampleRate)
            DispatchQueue.main.async {
                self?.state = .idle
                completion(captured, url, duration)
            }
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    #if DEBUG
    /// Прогон визуализации без микрофона: `-simulateSpectrum` в аргументах запуска.
    /// Нужен, чтобы смотреть оформление экрана записи на симуляторе.
    func startSimulation() {
        state = .recording
        var phase: Double = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            guard let self else { return }
            phase += 0.12
            var levels = [Float](repeating: 0, count: Self.bandCount)
            for i in 0..<Self.bandCount {
                let position = Double(i) / Double(Self.bandCount)
                // Спад к верхним частотам + несколько «дышащих» формант.
                let tilt = pow(1 - position, 1.4)
                let wobble = 0.55 + 0.45 * sin(phase * 1.7 + position * 9)
                let accent = 0.35 * sin(phase * 0.9 + position * 22)
                levels[i] = Float(max(0.02, min(1, tilt * wobble + accent * tilt)))
            }
            self.spectrum = levels
            self.level = 0.55 + 0.35 * Float(sin(phase * 1.3))
            self.elapsed += 1.0 / 24
        }
    }
    #endif

    func cancel() {
        startRequested = false
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
    }
}
