import SwiftUI

/// Экран результата сохранённой записи.
struct AnalysisView: View {
    let result: AnalysisResult
    let audioURL: URL?
    let title: String

    @StateObject private var player = AudioPlayerController()
    @State private var showAllChords = false

    /// Палитра считается один раз на запись и раздаётся вниз через окружение.
    private var palette: ChordPalette { ChordPalette(chords: usedChords) }

    var body: some View {
        // Экран не прокручивается целиком: шапка и плеер остаются на месте, а такты
        // занимают весь остаток высоты и листаются внутри себя. Иначе, чтобы дойти до
        // текущего такта, приходится уводить кнопку паузы за край экрана.
        VStack(alignment: .leading, spacing: 16) {
            summaryCard
            if audioURL != nil { playerCard }
            if !result.bars.isEmpty { barsCard }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .environment(\.chordPalette, palette)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { player.load(url: audioURL) }
        .onDisappear { player.stop() }
    }

    // MARK: - Карточки

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 0) {
                statistic(value: result.key ?? "—", caption: "тональность")
                Divider().frame(height: 40).overlay(Theme.textSecondary.opacity(0.3))
                statistic(value: "\(result.beatsPerBar)/4", caption: "размер")
                Divider().frame(height: 40).overlay(Theme.textSecondary.opacity(0.3))
                statistic(value: result.duration.asTimecode, caption: "длина")
            }
            // Не вся последовательность, а набор аккордов записи: по нему сразу видно,
            // на чём она держится, и он не растёт на пол-экрана вместе с длиной фрагмента.
            if !usedChords.isEmpty { chordLegend }
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
                                         : palette.color(for: currentChord))
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

    /// Набор аккордов записи. В одну строку влезает ограниченное число тэгов, поэтому
    /// остальные прячутся за счётчиком, а не переносятся на вторую строку — иначе шапка
    /// растёт и выдавливает такты с экрана.
    private var chordLegend: some View {
        let visible = showAllChords ? usedChords : Array(usedChords.prefix(inlineChordLimit))
        let hidden = usedChords.count - visible.count
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows(of: visible).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, chord in
                        ChordChip(label: chord, size: 15)
                    }
                    if row.last == visible.last, hidden > 0 || showAllChords {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                showAllChords.toggle()
                            }
                        } label: {
                            Text(showAllChords ? "свернуть" : "+\(hidden)")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(Theme.textSecondary.opacity(0.4), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var inlineChordLimit: Int { 4 }

    private func rows(of chords: [ChordLabel]) -> [[ChordLabel]] {
        stride(from: 0, to: chords.count, by: inlineChordLimit).map {
            Array(chords[$0..<min($0 + inlineChordLimit, chords.count)])
        }
    }

    /// Аккорды записи по убыванию звучащего времени — словарь, а не хронология.
    private var usedChords: [ChordLabel] {
        var weight: [ChordLabel: Double] = [:]
        for segment in result.chords where !segment.label.isNone {
            weight[segment.label, default: 0] += segment.duration
        }
        return weight.sorted { ($0.value, $1.key.name) > ($1.value, $0.key.name) }.map { $0.key }
    }

    private var barsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Такты").font(.headline).foregroundStyle(Theme.textPrimary)
            // Список едет сам за проигрыванием и держится в своей рамке: иначе, чтобы
            // увидеть текущий такт, приходится листать страницу и терять кнопку паузы.
            ScrollViewReader { proxy in
                ScrollView {
                    BarsGridView(bars: result.bars, currentTime: player.currentTime)
                        .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: activeBarID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .cardStyle()
        .frame(maxHeight: .infinity)
    }

    private var activeBarID: UUID? {
        result.bars.first { player.currentTime >= $0.start && player.currentTime < $0.end }?.id
    }

    private var currentChord: ChordLabel {
        result.chord(at: player.currentTime) ?? .none
    }
}
