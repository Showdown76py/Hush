#!/bin/bash
# aec3 voice test: one 15 s take (raw mic + system output) while user talks over music
# then offline rerun at several noise suppression levels
# usage: aec3_voice_test.sh <aec3cap> <music> <outdir>
set -euo pipefail
BIN="$1"; MUSIC="$2"; OUT="$3"
mkdir -p "$OUT"
say -v Thomas "Le test commence. Parlez dès que la musique démarre, jusqu'au signal de fin."
afplay -t 17 "$MUSIC" &
AF=$!
sleep 1
"$BIN" --dir "$OUT" --seconds 15 --ns 0 > "$OUT/log.txt"
kill $AF 2>/dev/null || true
say -v Thomas "Terminé, merci."
for ns in 0 2 3 4; do "$BIN-offline" "$OUT/raw.wav" "$OUT/ref.wav" "$ns" "$OUT/aec3_ns$ns.wav"; done
echo "Fichiers : $OUT/raw.wav (brut) et $OUT/aec3_ns{0,2,3,4}.wav"
