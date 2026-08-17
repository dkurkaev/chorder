import AVFoundation
import Foundation

/// Импорт готового аудиофайла: декодирование в моно 22.05 кГц (тот же формат,
/// что даёт микрофон), копия в локальное хранилище и сэмплы для анализа.
enum AudioImporter {

    enum Failure: LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "Не удалось прочитать файл"
            case .empty: "В файле нет звука"
            }
        }
    }

    struct Imported {
        let samples: [Float]
        let url: URL
        let duration: Double
        let title: String
        /// Файл был длиннее лимита и в анализ ушло только начало.
        let wasTrimmed: Bool
    }

    /// Столько же, сколько берём с микрофона: и память, и время анализа под контролем.
    static var maxDuration: Double { AudioRecorder.maxDuration }

    private static let queue = DispatchQueue(label: "com.chorder.import", qos: .userInitiated)

    /// Декодирует файл в фоне и подчищает за собой временную копию.
    static func load(from source: URL, completion: @escaping (Result<Imported, Error>) -> Void) {
        queue.async {
            let result = Result { try load(from: source) }
            if isTemporaryCopy(source) { try? FileManager.default.removeItem(at: source) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Передавая файл из другого приложения, система кладёт копию в Documents/Inbox —
    /// её нужно удалить. А вот файл, открытый «на месте», принадлежит пользователю,
    /// и трогать его нельзя.
    private static func isTemporaryCopy(_ url: URL) -> Bool {
        let inbox = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Inbox", isDirectory: true)
            .standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(inbox + "/")
    }

    static func load(from source: URL) throws -> Imported {
        // URL из пикера и из share-sheet живёт в чужой песочнице — нужен доступ на время чтения.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let file = try? AVAudioFile(forReading: source) else { throw Failure.unreadable }

        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0, file.length > 0 else { throw Failure.empty }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw Failure.unreadable
        }

        let limit = Int(AudioRecorder.sampleRate * maxDuration)
        let readSize: AVAudioFrameCount = 8192
        let outputCapacity = AVAudioFrameCount(
            Double(readSize) * target.sampleRate / sourceFormat.sampleRate
        ) + 1024

        var samples: [Float] = []
        samples.reserveCapacity(limit)
        var readFailed = false

        // Конвертер сам занимается ресемплом и сведением стерео в моно, поэтому
        // тянем данные из файла блоками через его input-колбэк.
        while samples.count < limit {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else { break }

            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: readSize) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: readSize)
                } catch {
                    readFailed = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }

            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }

            if status == .error || readFailed { throw Failure.unreadable }
            if status == .endOfStream { break }
        }

        if samples.count > limit { samples.removeLast(samples.count - limit) }
        guard !samples.isEmpty else { throw Failure.empty }

        guard let stored = AudioFileStore.shared.write(
            samples: samples, sampleRate: AudioRecorder.sampleRate
        ) else { throw Failure.unreadable }

        let sourceDuration = Double(file.length) / sourceFormat.sampleRate
        return Imported(
            samples: samples,
            url: stored,
            duration: Double(samples.count) / AudioRecorder.sampleRate,
            title: source.deletingPathExtension().lastPathComponent,
            wasTrimmed: sourceDuration > maxDuration + 0.05
        )
    }
}
