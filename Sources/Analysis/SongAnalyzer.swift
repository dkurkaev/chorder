import Foundation

/// Полный разбор фрагмента: хрома → аккорды → ритм → такты.
/// Чистый Foundation, без UI — можно гонять на любых сэмплах.
enum SongAnalyzer {

    /// Штраф аккорду, которого нет в словаре чистых мест. Подбор — через Tools/DSPCheck.
    static var outsidePenalty: Float = 0.9
    /// На сколько дешевеет переход, который песня действительно делает.
    static var transitionRelief: Float = 0.4
    /// Во сколько раз дороже переход, которого песня не делала. Единица — не штрафовать:
    /// на проверке штраф чаще выдавливал верный аккорд в редкую соседнюю окраску,
    /// чем исправлял ошибку.
    static var unknownTransitionFactor: Float = 1.0

    static func analyze(
        samples: [Float],
        sampleRate: Double,
        chordOptions: ChordRecognizer.Options? = nil,
        separation: SourceSeparator.Mode? = .full,
        useReferences: Bool = true,
        useTransitions: Bool = true,
        usePhrase: Bool = true,
        diagnostics: ((String) -> Void)? = nil
    ) -> AnalysisResult {
        let duration = Double(samples.count) / sampleRate
        guard duration > 0.5 else { return .empty }

        // Аккорды считаем по аккомпанементу: солирующая мелодия даёт ноты вне аккорда,
        // из-за которых распознаватель теряет аккорд или дёргается на соседний.
        // Ритм — по исходной записи: удары нужны целиком, их разделение только ослабляет.
        let separated = separation.map {
            SourceSeparator.separate(samples: samples, sampleRate: sampleRate, mode: $0)
        }
        let harmony = separated?.accompaniment ?? samples

        let chroma = ChromaExtractor.chromagram(samples: harmony, sampleRate: sampleRate)
        let beat = BeatTracker.analyze(samples: samples, sampleRate: sampleRate)
        let key = KeyEstimator.estimate(from: chroma)

        var beatOptions = chordOptions ?? ChordRecognizer.Options.beatSynchronous
        var frameOptions = ChordRecognizer.Options.default
        if let key {
            let context = ChordRecognizer.KeyContext(tonic: key.tonic, isMinor: key.isMinor)
            beatOptions.key = context
            frameOptions.key = context
        }

        // Без надёжного ритма разбираем покадрово — сетки долей просто нет.
        guard beat.beats.count >= 4 else {
            let chords = ChordRecognizer.segments(from: chroma, duration: duration, options: frameOptions)
            return AnalysisResult(
                duration: duration, bpm: (beat.bpm * 10).rounded() / 10,
                beatsPerBar: beat.beatsPerBar, beats: beat.beats, downbeatOffset: 0,
                key: key?.name, chords: chords, bars: [], tempoConfidence: beat.confidence
            )
        }

        // Октава темпа: автокорреляция одинаково хорошо объясняет период и его кратные,
        // поэтому спор решает гармония. Строим сетку для каждой гипотезы и берём ту,
        // при которой такты действительно ложатся на смену аккордов.
        var grid = bestGrid(
            beat: beat, chroma: chroma, duration: duration, options: beatOptions
        )

        // Второй проход по образцам из чистых мест. Там, где поёт голос, хрома засорена
        // нотами мелодии и аккорд «уплывает» на соседний. Но тот же аккорд почти наверняка
        // звучал где-то без голоса — оттуда и берём образец, с которым сверяемся.
        if useReferences, let melody = separated?.melody, !melody.isEmpty {
            let share = melodyShare(
                beats: grid.beats, melody: melody, accompaniment: harmony, sampleRate: sampleRate
            )
            let model = cleanModel(grid: grid, melodyShare: share)
            let names = model.vocabulary.map { ChordRecognizer.templates[$0].label.name }.sorted()
            diagnostics?("Словарь чистых мест: \(names.count) — \(names.joined(separator: ", "))")
            for (from, targets) in model.transitions.sorted(by: { $0.key < $1.key }) {
                let list = targets.sorted { $0.value > $1.value }
                    .map { "\(ChordRecognizer.templates[$0.key].label.name) \(Int($0.value * 100))%" }
                diagnostics?("  переходы из \(ChordRecognizer.templates[from].label.name): "
                             + list.joined(separator: ", "))
            }

            if !model.vocabulary.isEmpty {
                var refined = beatOptions
                refined.vocabulary = model.vocabulary
                refined.outsidePenalty = outsidePenalty
                refined.transitions = useTransitions ? model.transitions : nil
                refined.transitionRelief = transitionRelief
                refined.unknownTransitionFactor = unknownTransitionFactor
                let candidate = makeGrid(
                    beats: grid.beats, beat: beat, chroma: chroma,
                    duration: duration, options: refined
                )
                diagnostics?(String(format: "Оценка сетки: без словаря %.3f, со словарём %.3f",
                                    grid.score, candidate.score))
                if candidate.score >= grid.score { grid = candidate }
            }
        }

        // Фраза: песня крутит одну последовательность, и там, где её слышно плохо,
        // разумнее достроить по ней, чем верить испорченной хроме.
        if usePhrase, let melody = separated?.melody, !melody.isEmpty {
            let share = melodyShare(
                beats: grid.beats, melody: melody, accompaniment: harmony, sampleRate: sampleRate
            )
            if let tightened = applyPhrase(
                to: grid, beat: beat, duration: duration,
                melodyShare: share, diagnostics: diagnostics
            ) {
                grid = tightened
            }
        }

        // Лента и строка прогрессии должны показывать то же, что и такты: сетка уже
        // отбросила мусорное начало и убрала выбросы, и расходиться с ней нельзя.
        let finalChords = grid.bars.isEmpty ? grid.chords : segments(from: grid.bars, source: grid.chords)

        return AnalysisResult(
            duration: duration,
            bpm: (BeatTracker.bpm(from: grid.beats, fallback: beat.bpm) * 10).rounded() / 10,
            beatsPerBar: beat.beatsPerBar,
            beats: grid.beats,
            downbeatOffset: grid.startBeat,
            key: key?.name,
            chords: finalChords,
            bars: grid.bars,
            tempoConfidence: beat.confidence
        )
    }

    // MARK: - Словарь аккордов из чистых мест

    /// Какие аккорды песня играет там, где солиста не слышно.
    ///
    /// Голос портит хрому: поверх A#m звучит нота, и распознаватель уходит на A#m7 или Fm.
    /// Но тот же аккорд почти наверняка звучал и без голоса — там он определяется уверенно.
    /// Собрав такие места, получаем набор аккордов песни; дальше похожие места читаются
    /// как «свой, просто испорченный», а не как новая гармония.
    struct CleanModel {
        var vocabulary: Set<Int> = []
        /// Из какого аккорда в какой песня переходит и как часто (доли, сумма по строке 1).
        var transitions: [Int: [Int: Float]] = [:]
    }

    /// Насколько громко солист поёт на каждой доле — относительно аккомпанемента.
    static func melodyShare(
        beats: [Double], melody: [Float], accompaniment: [Float], sampleRate: Double
    ) -> [Double] {
        guard !beats.isEmpty, !melody.isEmpty else { return [] }
        var result: [Double] = []
        result.reserveCapacity(beats.count)
        for (index, start) in beats.enumerated() {
            let end = index + 1 < beats.count
                ? beats[index + 1]
                : start + (beats.count > 1 ? beats[1] - beats[0] : 0.5)
            let from = max(0, Int(start * sampleRate))
            let to = min(melody.count, Int(end * sampleRate))
            guard to > from else { result.append(1); continue }
            var melodyEnergy = 0.0
            var backgroundEnergy = 0.0
            for i in from..<to {
                melodyEnergy += Double(melody[i] * melody[i])
                if i < accompaniment.count {
                    backgroundEnergy += Double(accompaniment[i] * accompaniment[i])
                }
            }
            result.append(melodyEnergy / max(1e-12, melodyEnergy + backgroundEnergy))
        }
        return result
    }

    static func cleanModel(
        grid: Grid, melodyShare: [Double]
    ) -> CleanModel {
        guard !grid.beats.isEmpty, !melodyShare.isEmpty else { return CleanModel() }

        // Чистота считается по сегменту аккорда, а не по отдельной доле: доли, где голос
        // молчит, разбросаны поодиночке, и переходов из них не собрать.
        let labelToIndex = Dictionary(
            uniqueKeysWithValues: ChordRecognizer.templates.enumerated().map { ($1.label, $0) }
        )

        struct CleanSegment {
            var template: Int
            var share: Double
            var duration: Double
        }

        var segments: [CleanSegment] = []
        for segment in grid.chords where !segment.label.isNone {
            guard let template = labelToIndex[segment.label] else { continue }
            var sum = 0.0
            var count = 0
            for (index, beat) in grid.beats.enumerated()
            where index < melodyShare.count && beat >= segment.start && beat < segment.end {
                sum += melodyShare[index]
                count += 1
            }
            guard count > 0 else { continue }
            segments.append(CleanSegment(
                template: template, share: sum / Double(count), duration: segment.duration
            ))
        }
        guard !segments.isEmpty else { return CleanModel() }

        let threshold = segments.map { $0.share }.sorted()[segments.count / 2]

        // Вес аккорда — его время, взвешенное по чистоте звучания. Учитываем всю запись,
        // а не только тихую половину: аккорд, который почти всегда идёт под солистом,
        // иначе выпадет из словаря, и потом его нечем будет отличить от постороннего.
        var weight: [Int: Double] = [:]
        for segment in segments {
            weight[segment.template, default: 0] += segment.duration * (1 - segment.share)
        }
        guard !weight.isEmpty else { return CleanModel() }

        // Берём аккорды, покрывающие основное чистое время: редкие гости почти всегда
        // сами являются испорченной версией частого аккорда.
        let ranked = weight.keys.sorted { weight[$0]! > weight[$1]! }
        let total = weight.values.reduce(0, +)
        var vocabulary: Set<Int> = []
        var covered = 0.0
        for index in ranked {
            // Аккорд, на который приходятся считаные проценты чистого времени, — почти
            // всегда испорченная версия соседа, а не отдельная гармония.
            guard weight[index]! >= 0.08 * total else { break }
            vocabulary.insert(index)
            covered += weight[index]!
            if covered >= 0.9 * total { break }
        }

        // Какие смены песня делает. Берём пары соседних сегментов, где обе стороны слышно
        // чисто, — иначе в модель попадёт та самая ошибка, ради которой всё затевалось.
        var counts: [Int: [Int: Double]] = [:]
        for (previous, current) in zip(segments, segments.dropFirst()) {
            guard previous.share <= threshold, current.share <= threshold,
                  previous.template != current.template,
                  vocabulary.contains(previous.template), vocabulary.contains(current.template)
            else { continue }
            counts[previous.template, default: [:]][current.template, default: 0] += 1
        }

        var transitions: [Int: [Int: Float]] = [:]
        for (from, targets) in counts {
            let sum = targets.values.reduce(0, +)
            guard sum >= 2 else { continue }        // один случай — это не правило
            transitions[from] = targets.mapValues { Float($0 / sum) }
        }

        return CleanModel(vocabulary: vocabulary, transitions: transitions)
    }

    // MARK: - Фраза

    /// Достраивает такты по повторяющейся фразе записи.
    ///
    /// Меняем только доли, где запись сама себе противоречит: пусто или аккорд не из
    /// словаря песни. Там, где хрома уверенно говорит своё, фразу не навязываем — иначе
    /// потеряются настоящие отклонения от неё.
    static func applyPhrase(
        to grid: Grid, beat: BeatResult, duration: Double,
        melodyShare: [Double], diagnostics: ((String) -> Void)?
    ) -> Grid? {
        guard !grid.bars.isEmpty, !melodyShare.isEmpty else { return nil }

        let barChords = grid.bars.map { bar -> ChordLabel in
            var counts: [ChordLabel: Int] = [:]
            for chord in bar.beatChords { counts[chord, default: 0] += 1 }
            return counts.max { $0.value < $1.value }?.key ?? .none
        }

        // Фразу ищем по тактам, где солиста почти не слышно: под голосом аккорды сами
        // искажены, и фраза, снятая с них, закрепила бы ошибку вместо того чтобы её чинить.
        var barShare: [Double] = []
        for (index, bar) in grid.bars.enumerated() {
            _ = index
            var sum = 0.0
            var count = 0
            for (beatIndex, time) in grid.beats.enumerated()
            where beatIndex < melodyShare.count && time >= bar.start && time < bar.end {
                sum += melodyShare[beatIndex]
                count += 1
            }
            barShare.append(count > 0 ? sum / Double(count) : 1)
        }
        let quietLimit = barShare.sorted()[barShare.count / 2]
        let cleanBars = zip(barChords, barShare).filter { $0.1 <= quietLimit }.map { $0.0 }

        guard var phrase = PhraseModel.find(barChords: cleanBars, beatsPerBar: beat.beatsPerBar)
                ?? PhraseModel.find(barChords: barChords, beatsPerBar: beat.beatsPerBar) else {
            return nil
        }
        // Читаем фразу с того аккорда, с которого её играет запись, а не с произвольного
        // места кольца.
        if let opening = barChords.first(where: { !$0.isNone }) {
            phrase = PhraseModel.rotated(phrase, toStartWith: opening)
        }
        diagnostics?(String(
            format: "Фраза: %@ (по %d долей, покрытие %.0f%%)",
            phrase.chords.map { $0.name }.joined(separator: " – "),
            phrase.beatsPerChord, phrase.support * 100
        ))

        let labels = beatChords(beats: grid.beats, chords: grid.chords, duration: duration)
        let start = grid.startBeat
        guard start < labels.count else { return nil }
        let tail = Array(labels[start...])
        guard let expected = PhraseModel.expectedChords(phrase: phrase, beatChords: tail) else {
            diagnostics?("Фраза не согласуется с записью — оставляю как есть")
            return nil
        }

        let vocabulary = Set(phrase.chords)
        let noisyLimit = melodyShare.sorted()[melodyShare.count / 2]
        var corrected = labels
        var changes = 0
        for (offset, expectedChord) in expected.enumerated() {
            let index = start + offset
            guard index < corrected.count, corrected[index] != expectedChord else { continue }
            // Правим там, где хроме верить нельзя: доля пустая, аккорд вообще не из фразы,
            // либо поверх играет голос. Где солиста нет, а хрома уверенно говорит своё,
            // фразу не навязываем — иначе потеряются настоящие отклонения от неё.
            // Под голосом верим фразе только там, где аккорд явно «залип»: тянется с
            // предыдущей доли, хотя фраза давно ушла дальше. Просто громкий голос — ещё
            // не повод переписывать уверенно распознанный аккорд.
            let isNoisy = index < melodyShare.count && melodyShare[index] > noisyLimit
            let isStuck = index > 0 && corrected[index] == corrected[index - 1]
            guard corrected[index].isNone || !vocabulary.contains(corrected[index])
                    || (isNoisy && isStuck) else {
                continue
            }
            corrected[index] = expectedChord
            changes += 1
        }
        diagnostics?("Фраза поправила долей: \(changes)")
        guard changes > 0 else { return nil }

        let bars = buildBars(
            beats: grid.beats, beatsPerBar: beat.beatsPerBar,
            startBeat: start, beatChords: corrected, duration: duration
        )
        let chords = segments(from: bars, source: grid.chords)
        return Grid(
            beats: grid.beats, chords: chords, bars: bars, startBeat: start,
            score: gridScore(bars: bars, beats: grid.beats)
        )
    }

    // MARK: - Выбор сетки

    struct Grid {
        var beats: [Double]
        var chords: [ChordSegment]
        var bars: [Bar]
        var startBeat: Int
        /// Насколько хорошо такты объясняют гармонию: доля тактов под одним аккордом.
        var score: Double
    }

    /// Перебирает октавы темпа и возвращает сетку, лучше всего объясняющую гармонию.
    static func bestGrid(
        beat: BeatResult, chroma: [ChromaFrame], duration: Double, options: ChordRecognizer.Options
    ) -> Grid {
        var candidates: [[Double]] = [beat.beats]
        // Половинный период = вдвое более быстрый темп. Проверяем и его, и обратную
        // гипотезу, оставаясь в человеческом диапазоне.
        let period = beat.periodFrames
        if period > 2, !beat.onsetEnvelope.isEmpty {
            let bpm = 60.0 * beat.envelopeRate / period
            if bpm * 2 <= BeatTracker.maxBPM {
                candidates.append(BeatTracker.beats(
                    envelope: beat.onsetEnvelope, rate: beat.envelopeRate, periodFrames: period / 2
                ))
            }
            if bpm / 2 >= BeatTracker.minBPM {
                candidates.append(BeatTracker.beats(
                    envelope: beat.onsetEnvelope, rate: beat.envelopeRate, periodFrames: period * 2
                ))
            }
        }

        var best: Grid?
        for beats in candidates where beats.count >= 4 {
            let grid = makeGrid(
                beats: beats, beat: beat, chroma: chroma, duration: duration, options: options
            )
            if best == nil || grid.score > best!.score { best = grid }
        }
        return best ?? makeGrid(
            beats: beat.beats, beat: beat, chroma: chroma, duration: duration, options: options
        )
    }

    private static func makeGrid(
        beats: [Double], beat: BeatResult, chroma: [ChromaFrame],
        duration: Double, options: ChordRecognizer.Options
    ) -> Grid {
        let chords = ChordRecognizer.beatSynchronousSegments(
            frames: chroma, beats: beats, duration: duration, options: options
        )

        // Сетку тактов кладём на гармонию: сначала аккорд каждой доли, затем начало
        // осмысленной части и фаза, при которой границы тактов совпадают со сменой аккорда.
        let labels = beatChords(beats: beats, chords: chords, duration: duration)
        let firstBeat = firstMeaningfulBeat(
            beats: beats, beatChords: labels, beatsPerBar: beat.beatsPerBar,
            envelope: beat.onsetEnvelope, rate: beat.envelopeRate
        )
        let startBeat = estimateBarStart(
            beats: beats, beatChords: labels, from: firstBeat, beatsPerBar: beat.beatsPerBar,
            envelope: beat.onsetEnvelope, rate: beat.envelopeRate
        )
        let bars = buildBars(
            beats: beats, beatsPerBar: beat.beatsPerBar,
            startBeat: startBeat, beatChords: labels, duration: duration
        )

        return Grid(
            beats: beats, chords: chords, bars: bars, startBeat: startBeat,
            score: gridScore(bars: bars, beats: beats)
        )
    }

    /// Оценка сетки: доля тактов, целиком лежащих под одним аккордом. Такт, в котором
    /// аккорд меняется, — признак того, что мы делим музыку не там, где она делится.
    /// Слишком дробная сетка отсекается приором на привычный темп.
    private static func gridScore(bars: [Bar], beats: [Double]) -> Double {
        guard !bars.isEmpty, beats.count > 1 else { return 0 }
        let steady = bars.filter { bar in
            !(bar.beatChords.first?.isNone ?? true) && bar.beatChords.allSatisfy { $0 == bar.beatChords[0] }
        }.count
        let named = bars.flatMap { $0.beatChords }.filter { !$0.isNone }.count
        let total = max(1, bars.flatMap { $0.beatChords }.count)

        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let bpm = 60.0 / max(1e-6, intervals[intervals.count / 2])
        // Тот же лог-нормальный приор, что и при оценке темпа: без него побеждает
        // самая дробная сетка — в коротком такте аккорд не успевает смениться.
        let prior = exp(-0.5 * pow(log2(bpm / 120.0) / 1.1, 2))

        return (Double(steady) / Double(bars.count) + 0.35 * Double(named) / Double(total)) * prior
    }

    /// Сворачивает доли тактов обратно в отрезки аккордов: подряд идущие одинаковые
    /// доли склеиваются. Уверенность берём у исходных отрезков, накрывающих этот кусок.
    static func segments(from bars: [Bar], source: [ChordSegment]) -> [ChordSegment] {
        var result: [ChordSegment] = []
        for bar in bars {
            let beatCount = bar.beatChords.count
            guard beatCount > 0 else { continue }
            let beatLength = (bar.end - bar.start) / Double(beatCount)
            for (index, label) in bar.beatChords.enumerated() {
                let start = bar.start + Double(index) * beatLength
                let end = index == beatCount - 1 ? bar.end : start + beatLength
                if var last = result.last, last.label == label, abs(last.end - start) < 1e-6 {
                    last.end = end
                    result[result.count - 1] = last
                } else {
                    result.append(ChordSegment(
                        label: label, start: start, end: end,
                        confidence: confidence(in: source, from: start, to: end)
                    ))
                }
            }
        }
        return result
    }

    private static func confidence(in source: [ChordSegment], from start: Double, to end: Double) -> Double {
        var weighted = 0.0
        var total = 0.0
        for segment in source {
            let overlap = min(end, segment.end) - max(start, segment.start)
            guard overlap > 0 else { continue }
            weighted += segment.confidence * overlap
            total += overlap
        }
        return total > 0 ? weighted / total : 0
    }

    // MARK: - Такты

    /// Аккорд каждой доли — тот, что занимает большую часть её длительности.
    static func beatChords(beats: [Double], chords: [ChordSegment], duration: Double) -> [ChordLabel] {
        guard !beats.isEmpty else { return [] }
        let fallbackLength = beats.count > 1 ? beats[1] - beats[0] : 0.5
        return beats.enumerated().map { index, start in
            let end = index + 1 < beats.count ? beats[index + 1] : min(duration, start + fallbackLength)
            return dominantChord(in: chords, from: start, to: end)
        }
    }

    /// Первая доля, с которой сетка тактов вообще имеет смысл.
    ///
    /// В начале записи почти всегда есть кусок, который к музыке не относится: тишина
    /// перед первым звуком, шум комнаты, счёт палочками. Аккордов там нет, а доли,
    /// которые туда поставил трекер, — догадка, и такты из них выглядят случайными.
    /// Поэтому берём максимум из двух признаков: первый распознанный аккорд и момент,
    /// с которого доли подкреплены онсетами.
    static func firstMeaningfulBeat(
        beats: [Double],
        beatChords: [ChordLabel],
        beatsPerBar: Int,
        envelope: [Float],
        rate: Double
    ) -> Int {
        guard !beats.isEmpty else { return 0 }
        // Ведёт гармония: аккорд не распознаётся ни в тишине, ни в шуме, поэтому первый
        // не пустой аккорд — самый надёжный признак того, что музыка началась.
        var start = beatChords.firstIndex { !$0.isNone } ?? 0

        // Онсеты — только страховка от аккорда, померещившегося в шуме: сдвигаем начало
        // вперёд, пока в такте нет ни одного заметного удара.
        let support = onsetSupport(beats: beats, envelope: envelope, rate: rate)
        if !support.isEmpty {
            let threshold = support.sorted()[support.count / 2] * 0.3
            while threshold > 0, start + beatsPerBar <= support.count,
                  support[start..<(start + beatsPerBar)].allSatisfy({ $0 < threshold }) {
                start += 1
            }
        }
        // Не съедаем запись целиком, если признаки разошлись: оставляем хотя бы один такт.
        return min(start, max(0, beats.count - beatsPerBar))
    }

    /// Сила онсета под каждой долей. Удар может слегка разъезжаться с сеткой,
    /// поэтому берём максимум по небольшой окрестности.
    private static func onsetSupport(beats: [Double], envelope: [Float], rate: Double) -> [Float] {
        guard !envelope.isEmpty, rate > 0 else { return [] }
        let window = max(1, Int(0.05 * rate))
        return beats.map { time in
            let frame = Int((time * rate).rounded())
            guard frame >= 0, frame < envelope.count else { return 0 }
            let lower = max(0, frame - window)
            let upper = min(envelope.count - 1, frame + window)
            return envelope[lower...upper].max() ?? 0
        }
    }

    /// Доля, с которой начинается первый такт.
    ///
    /// Перебираем все фазы внутри такта и выбираем ту, при которой такты ложатся на
    /// гармонию: аккорд держится весь такт, а смены попадают на границы, а не в середину.
    /// Онсеты — только тайбрейк: на записи с микрофона они врут чаще, чем гармония.
    static func estimateBarStart(
        beats: [Double],
        beatChords: [ChordLabel],
        from firstBeat: Int,
        beatsPerBar: Int,
        envelope: [Float],
        rate: Double
    ) -> Int {
        guard beats.count > firstBeat + beatsPerBar else { return firstBeat }

        var bestStart = firstBeat
        var bestScore = -Double.greatestFiniteMagnitude
        for phase in 0..<beatsPerBar {
            let start = firstBeat + phase
            guard start + beatsPerBar <= beats.count else { break }

            var score: Double = 0
            var index = start
            while index + beatsPerBar <= beatChords.count {
                let slice = beatChords[index..<(index + beatsPerBar)]
                let changesInside = zip(slice, slice.dropFirst()).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
                if changesInside == 0 && !(slice.first?.isNone ?? true) {
                    score += 1                      // такт целиком под одним аккордом
                } else {
                    score -= 0.35 * Double(changesInside)
                }
                if index > 0, beatChords[index] != beatChords[index - 1] {
                    score += 0.6                    // смена аккорда пришлась на границу такта
                }
                index += beatsPerBar
            }
            score += 0.15 * averageOnset(beats: beats, envelope: envelope, rate: rate,
                                         from: start, step: beatsPerBar)

            if score > bestScore {
                bestScore = score
                bestStart = start
            }
        }
        return bestStart
    }

    /// Средняя сила онсетов на границах тактов — нормирована, чтобы не зависеть от их числа.
    private static func averageOnset(
        beats: [Double], envelope: [Float], rate: Double, from start: Int, step: Int
    ) -> Double {
        guard !envelope.isEmpty, rate > 0, step > 0 else { return 0 }
        var sum: Double = 0
        var count = 0
        var index = start
        while index < beats.count {
            let frame = Int((beats[index] * rate).rounded())
            if frame >= 0, frame < envelope.count { sum += Double(envelope[frame]) }
            count += 1
            index += step
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// Смена аккорда почти никогда не попадает на границу такта ровно: распознаватель то
    /// немного опережает её, то запаздывает, и в такте остаётся «хвостик» в одну долю.
    /// Если такая одиночная доля совпадает с аккордом соседнего такта — это край смены,
    /// и её место там, а не здесь. Настоящие смены внутри такта (два аккорда по половине)
    /// правило не трогает: у них середина такта неоднородна.
    private static func snapChordEdges(
        _ labels: [ChordLabel], startBeat: Int, beatsPerBar: Int
    ) -> [ChordLabel] {
        guard beatsPerBar >= 3 else { return labels }
        var result = labels
        var index = startBeat
        while index + beatsPerBar <= labels.count {
            let first = index
            let last = index + beatsPerBar - 1
            let middle = labels[(first + 1)...(last - 1)]
            // Соседей читаем из исходного массива: правки соседнего такта не должны
            // тянуть за собой цепочку.
            // Середина такта однородна — значит такт держится под одним аккордом, а крайние
            // доли, выбивающиеся из него, это либо край смены, уехавший к соседу, либо
            // выброс на стыке аккордов. И то и другое место в такте не заслужило.
            if let core = middle.first, middle.allSatisfy({ $0 == core }), !core.isNone {
                if labels[last] != core { result[last] = core }
                if labels[first] != core { result[first] = core }
            }
            index += beatsPerBar
        }
        return result
    }

    static func buildBars(
        beats: [Double],
        beatsPerBar: Int,
        startBeat: Int,
        beatChords: [ChordLabel],
        duration: Double
    ) -> [Bar] {
        guard beats.count > startBeat + beatsPerBar else { return [] }
        let labels = snapChordEdges(beatChords, startBeat: startBeat, beatsPerBar: beatsPerBar)

        var bars: [Bar] = []
        var index = startBeat
        while index + beatsPerBar <= beats.count {
            let slice = Array(labels[index..<(index + beatsPerBar)])
            let start = beats[index]
            let endBeat = index + beatsPerBar
            let end = endBeat < beats.count ? beats[endBeat] : duration
            bars.append(Bar(index: 0, start: start, end: end, beatChords: slice))
            index += beatsPerBar
        }

        // Хвост записи так же бессмыслен, как и начало: пустые такты в конце убираем.
        while let last = bars.last, last.beatChords.allSatisfy({ $0.isNone }) {
            bars.removeLast()
        }
        return bars.enumerated().map { position, bar in
            var renumbered = bar
            renumbered.index = position
            return renumbered
        }
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
