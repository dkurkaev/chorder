import SwiftUI

/// Живой спектр вокруг кнопки записи: лучи, растущие прямо от её края.
///
/// Спектр отражается относительно вертикальной оси, поэтому картинка симметрична
/// и не имеет стыка. В тишине лучей нет вообще — остаётся только кнопка.
struct PulseVisualizerView: View {
    let levels: [Float]
    var isActive: Bool
    /// Радиус, от которого начинаются лучи (край кнопки + зазор).
    var innerRadius: CGFloat = 110
    /// Длина луча на максимуме.
    var maxLength: CGFloat = 64
    /// Цвет у основания лучей — совпадает с цветом кнопки.
    var tint: Color = Theme.accent
    /// Компоненты этого же цвета: по ним считаются оттенки лучей без обращения к UIColor.
    var tintComponents: (red: Double, green: Double, blue: Double) = Theme.accentComponents

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let values = spectrumRing()
            let count = values.count
            guard count > 3 else { return }

            let circumference = 2 * CGFloat.pi * innerRadius
            let barWidth = min(6, max(3, circumference / CGFloat(count) * 0.62))

            for index in 0..<count {
                let level = values[index]
                guard level > 0.02 else { continue }

                let fraction = CGFloat(index) / CGFloat(count)
                let angle = -CGFloat.pi / 2 + fraction * 2 * .pi
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                let length = maxLength * level

                var path = Path()
                path.move(to: CGPoint(
                    x: center.x + direction.x * innerRadius,
                    y: center.y + direction.y * innerRadius
                ))
                path.addLine(to: CGPoint(
                    x: center.x + direction.x * (innerRadius + length),
                    y: center.y + direction.y * (innerRadius + length)
                ))

                // Громкие полосы — светлее и плотнее, тихие уходят в фон.
                let lift = 0.18 + 0.42 * Double(level)
                let shade = Color(
                    red: tintComponents.red + (1 - tintComponents.red) * lift,
                    green: tintComponents.green + (1 - tintComponents.green) * lift,
                    blue: tintComponents.blue + (1 - tintComponents.blue) * lift
                )
                context.stroke(
                    path,
                    with: .color(shade.opacity(0.45 + 0.55 * Double(level))),
                    style: StrokeStyle(lineWidth: barWidth, lineCap: .round)
                )
            }
        }
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.05), value: levels)
    }

    /// Спектр по кольцу: зеркальные половины + сглаживание соседей.
    private func spectrumRing() -> [CGFloat] {
        let count = max(3, levels.count)
        var mirrored: [CGFloat] = []
        mirrored.reserveCapacity(count * 2)
        for index in 0..<count { mirrored.append(CGFloat(levels[index])) }
        for index in stride(from: count - 1, through: 0, by: -1) { mirrored.append(CGFloat(levels[index])) }

        guard mirrored.count > 2 else { return mirrored }
        var smoothed = mirrored
        let total = mirrored.count
        for i in 0..<total {
            let previous = mirrored[(i - 1 + total) % total]
            let following = mirrored[(i + 1) % total]
            smoothed[i] = previous * 0.25 + mirrored[i] * 0.5 + following * 0.25
        }
        return smoothed
    }
}
