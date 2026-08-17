import Foundation

/// Полный разбор фрагмента: хрома → аккорды → ритм → такты.
/// Чистый Foundation, без UI — можно гонять на любых сэмплах.
enum SongAnalyzer {

    static func analyze(
        samples: [Float],
        sampleRate: Double,
        chordOptions: ChordRecognizer.Options? = nil
    ) -> AnalysisResult {
        let duration = Double(samples.count) / sampleRate
        guard duration > 0.5 else { return .empty }

        let chroma = ChromaExtractor.chromagram(samples: samples, sampleRate: sampleRate)
        let beat = BeatTracker.analyze(samples: samples, sampleRate: sampleRate)
        let key = KeyEstimator.estimate(from: chroma)

        var beatOptions = chordOptions ?? ChordRecognizer.Options.beatSynchronous
        var frameOptions = ChordRecognizer.Options.default
        if let key {
            let context = ChordRecognizer.KeyContext(tonic: key.tonic, isMinor: key.isMinor)
            beatOptions.key = context
            frameOptions.key = context
        }

        // Разбор по долям устойчивее: хрома усредняется внутри доли, границы аккордов
        // попадают на сетку ритма. Без надёжного ритма падаем обратно на покадровый разбор.
        let chords: [ChordSegment]
        if beat.beats.count >= 4 {
            chords = ChordRecognizer.beatSynchronousSegments(
                frames: chroma, beats: beat.beats, duration: duration, options: beatOptions
            )
        } else {
            chords = ChordRecognizer.segments(from: chroma, duration: duration, options: frameOptions)
        }

        // Сильную долю уточняем уже зная, где меняются аккорды.
        let downbeatOffset = BeatTracker.estimateDownbeat(
            beats: beat.beats,
            envelope: beat.onsetEnvelope,
            rate: beat.envelopeRate,
            beatsPerBar: beat.beatsPerBar,
            chordChanges: chords.dropFirst().map { $0.start }
        )

        let bars = buildBars(
            beats: beat.beats,
            beatsPerBar: beat.beatsPerBar,
            downbeatOffset: downbeatOffset,
            chords: chords,
            duration: duration
        )

        return AnalysisResult(
            duration: duration,
            bpm: (beat.bpm * 10).rounded() / 10,
            beatsPerBar: beat.beatsPerBar,
            beats: beat.beats,
            downbeatOffset: downbeatOffset,
            key: key?.name,
            chords: chords,
            bars: bars,
            tempoConfidence: beat.confidence
        )
    }

    // MARK: - Такты

    static func buildBars(
        beats: [Double],
        beatsPerBar: Int,
        downbeatOffset: Int,
        chords: [ChordSegment],
        duration: Double
    ) -> [Bar] {
        guard beats.count > beatsPerBar else { return [] }

        // Аккорд каждой доли — тот, что занимает большую часть её длительности.
        var beatChords: [ChordLabel] = []
        beatChords.reserveCapacity(beats.count)
        for (index, start) in beats.enumerated() {
            let end = index + 1 < beats.count ? beats[index + 1] : min(duration, start + (beats.count > 1 ? beats[1] - beats[0] : 0.5))
            beatChords.append(dominantChord(in: chords, from: start, to: end))
        }

        var bars: [Bar] = []
        var index = downbeatOffset
        var barIndex = 0
        while index < beats.count {
            let slice = Array(beatChords[index..<min(index + beatsPerBar, beatChords.count)])
            guard !slice.isEmpty else { break }
            let start = beats[index]
            let endBeat = index + beatsPerBar
            let end = endBeat < beats.count ? beats[endBeat] : duration
            bars.append(Bar(index: barIndex, start: start, end: end, beatChords: slice))
            barIndex += 1
            index += beatsPerBar
        }
        return bars
    }

    private static func dominantChord(in chords: [ChordSegment], from start: Double, to end: Double) -> ChordLabel {
        var best = ChordLabel.none
        var bestOverlap = 0.0
        for segment in chords {
            let overlap = min(end, segment.end) - max(start, segment.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = segment.label
            }
        }
        return best
    }
}
