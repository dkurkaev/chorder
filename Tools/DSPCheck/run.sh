#!/bin/bash
# Прогон DSP-конвейера на синтетическом сигнале или на файле (macOS, без Xcode-проекта).
# Собираются только слои моделей/DSP/анализа — UI и SwiftData сюда не входят.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/dspcheck"
swiftc -O \
  Sources/Models/ChordLabel.swift \
  Sources/Models/AnalysisResult.swift \
  Sources/DSP/FFTProcessor.swift \
  Sources/DSP/STFT.swift \
  Sources/DSP/SourceSeparator.swift \
  Sources/DSP/ChromaExtractor.swift \
  Sources/DSP/ChordRecognizer.swift \
  Sources/DSP/BeatTracker.swift \
  Sources/DSP/KeyEstimator.swift \
  Sources/Analysis/PhraseModel.swift \
  Sources/Analysis/SongAnalyzer.swift \
  Sources/Analysis/DemoSignal.swift \
  Tools/DSPCheck/main.swift \
  -o "$OUT"
"$OUT" "$@"
