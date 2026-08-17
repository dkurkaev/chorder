import Foundation
import SwiftData

/// Сохранённый разбор. Сам результат лежит JSON-ом в `resultData`,
/// а «шапка» вынесена в поля, чтобы список открывался без декодирования.
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

    init(title: String, result: AnalysisResult, audioURL: URL?) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.duration = result.duration
        self.bpm = result.bpm
        self.key = result.key
        self.progression = result.progressionSummary
        self.audioFileName = audioURL?.lastPathComponent
        self.resultData = (try? JSONEncoder().encode(result)) ?? Data()
    }

    var result: AnalysisResult {
        (try? JSONDecoder().decode(AnalysisResult.self, from: resultData)) ?? .empty
    }

    var audioURL: URL? {
        guard let audioFileName else { return nil }
        let url = AudioFileStore.shared.url(for: audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
