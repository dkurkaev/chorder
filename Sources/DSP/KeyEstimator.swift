import Foundation

/// Тональность методом Крумхансл — Шмуклер: корреляция усреднённой хромы с профилями лада.
enum KeyEstimator {
    private static let majorProfile: [Double] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88
    ]
    private static let minorProfile: [Double] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17
    ]

    struct Key {
        var tonic: Int
        var isMinor: Bool
        var correlation: Double

        var name: String {
            ChordLabel.pitchNames[((tonic % 12) + 12) % 12] + (isMinor ? "m" : "")
        }
    }

    static func estimate(from frames: [ChromaFrame]) -> Key? {
        guard !frames.isEmpty else { return nil }
        var average = [Double](repeating: 0, count: 12)
        for frame in frames {
            for i in 0..<12 { average[i] += Double(frame.values[i]) }
        }
        for i in 0..<12 { average[i] /= Double(frames.count) }

        var best: Key?
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let profile = isMinor ? minorProfile : majorProfile
                let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                let correlation = pearson(average, rotated)
                if best == nil || correlation > best!.correlation {
                    best = Key(tonic: tonic, isMinor: isMinor, correlation: correlation)
                }
            }
        }
        return best
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var numerator = 0.0, denomA = 0.0, denomB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            numerator += da * db
            denomA += da * da
            denomB += db * db
        }
        let denominator = sqrt(denomA * denomB)
        return denominator > 0 ? numerator / denominator : 0
    }
}
