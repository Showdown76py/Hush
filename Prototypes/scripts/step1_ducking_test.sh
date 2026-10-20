#!/bin/bash
# step 1: music (afplay) + raw mic (ffmpeg 20 s) + vp started at t=4 s for 10 s
# if ducking were on the music level in the raw mic would drop during [4,14] s
# usage: step1_ducking_test.sh <music file> <outdir> [--duck]
set -euo pipefail
MUSIC="$1"; OUT="$2"; shift 2
BIN="$(dirname "$0")/../.build/debug/vpcapture"
mkdir -p "$OUT"
if [ -n "${SYSTAP:-}" ]; then
  "$(dirname "$0")/../.build/debug/systap" --seconds 20 --out "$OUT/systap.wav" > "$OUT/systap.log" 2>&1 &
else
  ffmpeg -hide_banner -loglevel error -y -f avfoundation -i ":${RAWDEV:-MacBook Air Microphone}" -t 20 -ac 1 -ar 48000 "$OUT/raw_parallel.wav" &
fi
FF=$!
sleep 0.5
afplay -t 21 "$MUSIC" &
AF=$!
sleep 3.5
"$BIN" --seconds 10 --out "$OUT/vp.wav" "$@" ${VPINPUT:+--input "$VPINPUT"} > "$OUT/vp.log" 2>&1
wait $FF
kill $AF 2>/dev/null || true
echo "done"
