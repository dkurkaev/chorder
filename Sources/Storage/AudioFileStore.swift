import AVFoundation
import Foundation

/// Локальное хранилище аудиофрагментов в Documents/Recordings.
final class AudioFileStore {
    static let shared = AudioFileStore()

    private let directory: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Пишет моно-сэмплы в .caf и возвращает URL файла.
    @discardableResult
    func write(samples: [Float], sampleRate: Double) -> URL? {
        guard !samples.isEmpty else { return nil }
        let fileName = "\(UUID().uuidString).caf"
        let fileURL = url(for: fileName)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunkSize = 8192
            var offset = 0
            while offset < samples.count {
                let count = min(chunkSize, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
                }
                try file.write(from: buffer)
                offset += count
            }
            return fileURL
        } catch {
            return nil
        }
    }

    func delete(fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}
