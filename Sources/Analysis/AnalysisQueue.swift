import Foundation
import SwiftData

/// Фоновый разбор сохранённых записей.
/// Запись появляется в библиотеке сразу, результат дописывается по готовности.
///
/// Через потоки передаётся только `ModelContainer` (он Sendable) — сам `ModelContext`
/// берётся уже на главном акторе, поэтому `@Query` в списке видит изменения сразу.
@MainActor
final class AnalysisQueue: ObservableObject {
    /// Сколько записей сейчас в работе.
    @Published private(set) var activeCount = 0

    private let queue = DispatchQueue(label: "com.chorder.analysis", qos: .userInitiated)

    func enqueue(recordID: UUID, samples: [Float], sampleRate: Double, container: ModelContainer) {
        activeCount += 1
        queue.async { [weak self] in
            let result = SongAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
            Task { @MainActor in
                self?.finish(recordID: recordID, result: result, container: container)
            }
        }
    }

    private func finish(recordID: UUID, result: AnalysisResult, container: ModelContainer) {
        activeCount = max(0, activeCount - 1)

        let context = container.mainContext
        let descriptor = FetchDescriptor<SongRecord>(predicate: #Predicate { $0.id == recordID })
        guard let record = try? context.fetch(descriptor).first else { return }
        record.apply(result)
        try? context.save()
    }
}
