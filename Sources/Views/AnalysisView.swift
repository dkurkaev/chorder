import SwiftUI

/// Экран результата сохранённой записи.
struct AnalysisView: View {
    let result: AnalysisResult
    let audioURL: URL?
    let title: String

    @StateObject private var player = AudioPlayerController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard
                if audioURL != nil { playerCard }
                if !result.bars.isEmpty { barsCard }
                if !result.chords.isEmpty { timelineCard }
                if !result.chords.isEmpty { segmentsCard }
            }
            .padding(16)
            .padding(.bottom, 60)   // чтобы последняя карточка не пряталась под таб-баром
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { player.load(url: audioURL) }
        .onDisappear { player.stop() }
    }

    // MARK: - Карточки

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                statistic(value: result.bpm > 0 ? String(format: "%.0f", result.bpm) : "—", caption: "BPM")
                Divider().frame(height: 40).overlay(Theme.textSecondary.opacity(0.3))
                statistic(value: result.key ?? "—", caption: "тональность")
                Divider().frame(height: 40).overlay(Theme.textSecondary.opacity(0.3))
                statistic(value: "\(result.beatsPerBar)/4", caption: "размер")
                Divider().frame(height: 40).overlay(Theme.textSecondary.opacity(0.3))
                statistic(value: result.duration.asTimecode, caption: "длина")
            }
            if !result.progressionSummary.isEmpty {
                Text(result.progressionSummary)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            if result.tempoConfidence < 0.4 {
                Label("Ритм определён неуверенно — попробуй записать фрагмент подлиннее или погромче",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.accentWarm)
            }
        }
        .cardStyle()
    }

    private func statistic(value: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var playerCard: some View {
        HStack(spacing: 14) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(currentChord.isNone ? "Прослушать фрагмент" : currentChord.name)
                        .font(currentChord.isNone
                              ? .system(size: 16, weight: .medium)
                              : .system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(currentChord.isNone
                                         ? Theme.textPrimary
                                         : Theme.color(for: currentChord))
                    Spacer()
                    Text("\(player.currentTime.asDurationLabel) / \(result.duration.asDurationLabel)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                progressBar
            }
        }
        .cardStyle()
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            let fraction = result.duration > 0
                ? min(1, max(0, player.currentTime / result.duration))
                : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceHigh)
                Capsule().fill(Theme.accent)
                    .frame(width: geometry.size.width * fraction)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    guard geometry.size.width > 0 else { return }
                    player.seek(to: Double(value.location.x / geometry.size.width) * result.duration)
                }
            )
        }
        .frame(height: 5)
    }

    private var barsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Такты").font(.headline).foregroundStyle(Theme.textPrimary)
            BarsGridView(bars: result.bars, currentTime: player.currentTime)
        }
        .cardStyle()
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Лента аккордов").font(.headline).foregroundStyle(Theme.textPrimary)
            ChordTimelineView(
                segments: result.chords,
                duration: result.duration,
                currentTime: player.currentTime,
                onSeek: { player.seek(to: $0) }
            )
        }
        .cardStyle()
    }

    private var segmentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Хронология").font(.headline).foregroundStyle(Theme.textPrimary)
            ForEach(result.chords) { segment in
                HStack(spacing: 12) {
                    Text(segment.start.asTimecode)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    ChordChip(
                        label: segment.label,
                        isActive: player.currentTime >= segment.start && player.currentTime < segment.end
                    )
                    Spacer()
                    Text(String(format: "%.1f с", segment.duration))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { player.seek(to: segment.start) }
            }
        }
        .cardStyle()
    }

    private var currentChord: ChordLabel {
        result.chord(at: player.currentTime) ?? .none
    }
}
