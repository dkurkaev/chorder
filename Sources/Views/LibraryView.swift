import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SongRecord.createdAt, order: .reverse) private var records: [SongRecord]

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(records) { record in
                            NavigationLink {
                                AnalysisView(result: record.result, audioURL: record.audioURL, title: record.title)
                            } label: {
                                row(for: record)
                            }
                            .listRowBackground(Theme.surface)
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Записи")
        }
    }

    private func row(for record: SongRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                Label(String(format: "%.0f BPM", record.bpm), systemImage: "metronome")
                if let key = record.key {
                    Label(key, systemImage: "music.quarternote.3")
                }
                Label(record.duration.asTimecode, systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            if !record.progression.isEmpty {
                Text(record.progression)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Theme.textSecondary)
            Text("Пока пусто")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Запиши фрагмент на вкладке «Слушать» — разбор появится здесь.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 40)
        }
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
