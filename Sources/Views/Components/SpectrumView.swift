import SwiftUI

/// Круговой спектр: полосы расходятся лучами от кнопки записи.
/// Низкие частоты сверху, дальше по часовой стрелке до верхних.
struct RadialSpectrumView: View {
    let levels: [Float]
    var isActive: Bool
    /// Радиус кольца, от которого растут лучи.
    var innerRadius: CGFloat = 92
    /// Максимальная длина луча.
    var maxLength: CGFloat = 52

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let count = max(1, levels.count)
            let barWidth = max(2.5, (2 * .pi * innerRadius) / CGFloat(count) * 0.55)

            // Опорное кольцо — чтобы визуализация читалась и в тишине.
            let ring = Path(ellipseIn: CGRect(
                x: center.x - innerRadius, y: center.y - innerRadius,
                width: innerRadius * 2, height: innerRadius * 2
            ))
            context.stroke(ring, with: .color(Theme.accent.opacity(isActive ? 0.22 : 0.12)), lineWidth: 1)

            for index in 0..<count {
                let level = CGFloat(max(0.02, min(1, levels[index])))
                let angle = -CGFloat.pi / 2 + (CGFloat(index) / CGFloat(count)) * 2 * .pi
                let direction = CGPoint(x: cos(angle), y: sin(angle))

                let from = CGPoint(
                    x: center.x + direction.x * innerRadius,
                    y: center.y + direction.y * innerRadius
                )
                let to = CGPoint(
                    x: center.x + direction.x * (innerRadius + maxLength * level),
                    y: center.y + direction.y * (innerRadius + maxLength * level)
                )

                var path = Path()
                path.move(to: from)
                path.addLine(to: to)

                // Цвет от холодного к тёплому по мере роста частоты.
                let hueShift = Double(index) / Double(count)
                let color = Theme.accent.mix(with: Theme.accentWarm, by: hueShift)
                context.stroke(
                    path,
                    with: .color(color.opacity(isActive ? 0.45 + 0.55 * Double(level) : 0.18)),
                    style: StrokeStyle(lineWidth: barWidth, lineCap: .round)
                )
            }
        }
        .animation(.linear(duration: 0.06), value: levels)
        .allowsHitTesting(false)
    }
}

private extension Color {
    /// Линейное смешивание в sRGB — Color.mix доступен только с iOS 18.
    func mix(with other: Color, by amount: Double) -> Color {
        let lhs = UIColor(self).cgColor.components ?? [0, 0, 0, 1]
        let rhs = UIColor(other).cgColor.components ?? [0, 0, 0, 1]
        guard lhs.count >= 3, rhs.count >= 3 else { return self }
        let t = max(0, min(1, amount))
        return Color(
            red: Double(lhs[0]) * (1 - t) + Double(rhs[0]) * t,
            green: Double(lhs[1]) * (1 - t) + Double(rhs[1]) * t,
            blue: Double(lhs[2]) * (1 - t) + Double(rhs[2]) * t
        )
    }
}
