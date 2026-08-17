import SwiftUI

struct ChordChip: View {
    let label: ChordLabel
    var isActive: Bool = false
    var size: CGFloat = 15

    var body: some View {
        Text(label.isNone ? "—" : label.name)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(label.isNone ? Theme.textSecondary : Color.black.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.color(for: label))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white, lineWidth: isActive ? 2 : 0)
            )
            .scaleEffect(isActive ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)
    }
}

/// Сетка тактов: номер такта + аккорды по долям.
struct BarsGridView: View {
    let bars: [Bar]
    let currentTime: Double

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(bars) { bar in
                let isActive = currentTime >= bar.start && currentTime < bar.end
                VStack(alignment: .leading, spacing: 8) {
                    Text("Такт \(bar.index + 1)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        ForEach(Array(bar.uniqueChords.enumerated()), id: \.offset) { _, chord in
                            ChordChip(label: chord, size: 14)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isActive ? Theme.surfaceHigh : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.accent.opacity(isActive ? 0.8 : 0), lineWidth: 1.5)
                )
            }
        }
    }
}

/// Горизонтальная лента аккордов по времени.
struct ChordTimelineView: View {
    let segments: [ChordSegment]
    let duration: Double
    let currentTime: Double
    var onSeek: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        let fraction = duration > 0 ? segment.duration / duration : 0
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.color(for: segment.label))
                            .frame(width: max(2, width * fraction - 2))
                            .overlay(
                                Text(segment.label.isNone ? "" : segment.label.name)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.black.opacity(0.8))
                                    .lineLimit(1)
                                    .padding(.horizontal, 2)
                            )
                    }
                }
                if duration > 0 {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .offset(x: width * min(1, max(0, currentTime / duration)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    guard duration > 0, width > 0 else { return }
                    onSeek?(Double(value.location.x / width) * duration)
                }
            )
        }
        .frame(height: 44)
    }
}
