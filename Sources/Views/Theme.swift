import SwiftUI

enum Theme {
    static let background = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let surface = Color(red: 0.11, green: 0.12, blue: 0.16)
    static let surfaceHigh = Color(red: 0.16, green: 0.17, blue: 0.22)
    static let accent = Color(red: 0.42, green: 0.78, blue: 0.98)
    static let accentWarm = Color(red: 0.98, green: 0.60, blue: 0.35)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)

    /// Цвет аккорда по основному тону — квинтовый круг даёт приятный разброс оттенков.
    static func color(for label: ChordLabel) -> Color {
        guard let root = label.root else { return Color.white.opacity(0.18) }
        let positionInCircleOfFifths = (root * 7) % 12
        let hue = Double(positionInCircleOfFifths) / 12.0
        let isMinor = label.quality == .minor || label.quality == .minor7
        return Color(hue: hue, saturation: isMinor ? 0.42 : 0.62, brightness: isMinor ? 0.72 : 0.88)
    }
}

extension View {
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension Double {
    /// Длительность в списке записей: «0:14».
    var asDurationLabel: String {
        let total = Int(max(0, self).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var asTimecode: String {
        let total = max(0, self)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let tenths = Int((total - floor(total)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }
}
