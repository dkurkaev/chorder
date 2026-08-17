import Foundation
import SwiftData

enum RecordStatus: String, Codable {
    case analyzing
    case ready
    case failed
}

/// Сохранённая запись. Создаётся сразу после остановки микрофона — ещё без разбора,
/// результат дописывается, когда анализ закончится.
@Model
final class SongRecord {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var duration: Double = 0
    var bpm: Double = 0
    var key: String?
    var progression: String = ""
    var audioFileName: String?
    var resultData: Data = Data()
    var statusRaw: String = RecordStatus.analyzing.rawValue

    init(title: String, duration: Double, audioURL: URL?) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.duration = duration
        self.audioFileName = audioURL?.lastPathComponent
        self.statusRaw = RecordStatus.analyzing.rawValue
    }

    var status: RecordStatus {
        get { RecordStatus(rawValue: statusRaw) ?? .analyzing }
        set { statusRaw = newValue.rawValue }
    }

    var result: AnalysisResult? {
        guard !resultData.isEmpty else { return nil }
        return try? JSONDecoder().decode(AnalysisResult.self, from: resultData)
    }

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        let url = AudioFileStore.shared.url(for: audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Записывает результат разбора и переводит запись в готовое состояние.
    func apply(_ result: AnalysisResult) {
        resultData = (try? JSONEncoder().encode(result)) ?? Data()
        duration = result.duration > 0 ? result.duration : duration
        bpm = result.bpm
        key = result.key
        progression = result.progressionSummary
        status = result.isEmpty ? .failed : .ready
    }

    func markFailed() {
        status = .failed
    }
}
