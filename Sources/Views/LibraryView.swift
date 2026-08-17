import SwiftData
import SwiftUI

/// Список записей в духе «Диктофона»: прозрачные строки на общем фоне,
/// системные разделители и свайп для удаления.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: AppRouter
    @Query(sort: \SongRecord.createdAt, order: .reverse) private var records: [SongRecord]
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if records.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Записи")
            .navigationDestination(for: UUID.self) { recordID in
                RecordDetailView(recordID: recordID)
            }
        }
        .onChange(of: router.recordToOpen) { _, recordID in
            guard let recordID else { return }
            path = [recordID]
            router.recordToOpen = nil
        }
    }

    private var list: some View {
        List {
            ForEach(records) { record in
                NavigationLink(value: record.id) {
                    row(for: record)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                .listRowSeparatorTint(Color.white.opacity(0.12))
            }
            .onDelete(perform: delete)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(for record: SongRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(record.duration.asDurationLabel)
                    .font(.system(size: 15))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }

            switch record.status {
            case .analyzing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(Theme.textSecondary)
                    Text("Разбираю аккорды и ритм…")
                }
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            case .failed:
                Text("Не удалось разобрать фрагмент")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accentWarm)
            case .ready:
                HStack(spacing: 6) {
                    Text(String(format: "%.0f BPM", record.bpm))
                    if let key = record.key {
                        Text("·")
                        Text(key)
                    }
                    if !record.progression.isEmpty {
                        Text("·")
                        Text(record.progression)
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textSecondary)
            Text("Пока пусто")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Подержи кнопку на вкладке «Слушать» — разбор появится здесь.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let record = records[index]
            AudioFileStore.shared.delete(fileName: record.audioFileName)
            modelContext.delete(record)
        }
        try? modelContext.save()
    }
}

/// Экран записи: пока идёт разбор — прогресс, потом результат.
struct RecordDetailView: View {
    let recordID: UUID
    @Query private var records: [SongRecord]

    init(recordID: UUID) {
        self.recordID = recordID
        _records = Query(filter: #Predicate<SongRecord> { $0.id == recordID })
    }

    var body: some View {
        Group {
            if let record = records.first {
                switch record.status {
                case .analyzing:
                    status(icon: nil, title: "Разбираю аккорды и ритм…",
                           subtitle: "Обычно это занимает пару секунд")
                case .failed:
                    status(icon: "exclamationmark.triangle", title: "Не удалось разобрать",
                           subtitle: "Похоже, во фрагменте не слышно гармонии. Попробуй записать погромче или подлиннее.")
                case .ready:
                    AnalysisView(
                        result: record.result ?? .empty,
                        audioURL: record.audioURL,
                        title: record.title
                    )
                }
            } else {
                status(icon: "trash", title: "Запись удалена", subtitle: "")
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func status(icon: String?, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accentWarm)
            } else {
                ProgressView().controlSize(.large).tint(Theme.accent)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
