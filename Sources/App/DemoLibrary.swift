#if DEBUG
import Foundation
import SwiftData

/// Наполнение библиотеки демо-записями для отладки интерфейса без микрофона.
/// Включается флагом запуска `-seedDemoLibrary` (Scheme → Arguments или `simctl launch`).
enum DemoLibrary {
    static var isRequested: Bool {
        CommandLine.arguments.contains("-seedDemoLibrary")
    }

    /// Открыть первую запись сразу после запуска — удобно для скриншотов.
    static var shouldOpenFirstRecord: Bool {
        CommandLine.arguments.contains("-openFirstRecord")
    }

    @MainActor
    static func seed(into context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<SongRecord>())) ?? []
        guard existing.isEmpty else { return }

        let sampleRate = AudioRecorder.sampleRate
        let samples = DemoSignal.makeNoisy(sampleRate: sampleRate, duration: 16)
        let url = AudioFileStore.shared.write(samples: samples, sampleRate: sampleRate)
        let result = SongAnalyzer.analyze(samples: samples, sampleRate: sampleRate)

        let ready = SongRecord(title: "17 августа, 22:41", duration: result.duration, audioURL: url)
        ready.apply(result)
        ready.createdAt = Date()
        context.insert(ready)

        let analyzing = SongRecord(title: "17 августа, 21:05", duration: 24.3, audioURL: nil)
        analyzing.createdAt = Date().addingTimeInterval(-5400)
        context.insert(analyzing)

        let failed = SongRecord(title: "16 августа, 19:12", duration: 8.1, audioURL: nil)
        failed.markFailed()
        failed.createdAt = Date().addingTimeInterval(-100_000)
        context.insert(failed)

        try? context.save()
    }
}
#endif
