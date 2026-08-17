#!/bin/bash
# Прогон DSP-конвейера на синтетическом сигнале (macOS, без Xcode-проекта).
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/dspcheck"
swiftc -O \
  Sources/Models/*.swift \
  Sources/DSP/*.swift \
  Sources/Analysis/*.swift \
  Tools/DSPCheck/main.swift \
  -o "$OUT"
"$OUT" "$@"
