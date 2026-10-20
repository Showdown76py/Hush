#!/bin/bash
# step 3: test w/ user's voice + music
# vp2out (mic -> vp -> blackhole) + dualrec (raw builtin mic | blackhole) aligned by timestamp
# usage: step3_voice_test.sh <music> <outdir> [vp2out args...]
set -eu
MUSIC="$1"; OUT="$2"; shift 2
B="$(dirname "$0")/../.build/debug"
mkdir -p "$OUT"
say -v Thomas "Le test commence. Parlez dès que la musique démarre, jusqu'au signal de fin."
"$B/vp2out" --target 256 --buffer 128 --seconds 22 "$@" > "$OUT/vp2out.log" 2>&1 &
VP=$!; sleep 3          # let vp start and converge
afplay -t 19 "$MUSIC" &
AF=$!
"$B/dualrec" --b "${BDEV:-BlackHole 16ch}" --seconds 17 --out "$OUT/dual.wav" > "$OUT/dualrec.log" 2>&1
wait $VP; kill $AF 2>/dev/null || true
say -v Thomas "Terminé, merci."
ffmpeg -v error -y -i "$OUT/dual.wav" -af "pan=mono|c0=c0" "$OUT/brut.wav"
ffmpeg -v error -y -i "$OUT/dual.wav" -af "pan=mono|c0=c1" "$OUT/nettoye.wav"
echo "ok"
