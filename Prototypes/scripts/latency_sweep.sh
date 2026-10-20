#!/bin/bash
# transport latency (vp bypassed) for several (ring target, blackhole buffer) pairs
# usage: latency_sweep.sh <music> <outdir> "target:buffer" ...
set -u
MUSIC="$1"; OUT="$2"; shift 2
B="$(dirname "$0")/../.build/debug"
mkdir -p "$OUT"
for cfg in "$@"; do
  T="${cfg%%:*}"; BUF="${cfg##*:}"
  "$B/vp2out" --bypass --target "$T" --buffer "$BUF" --seconds 13 > "$OUT/b_${T}_${BUF}.log" 2>&1 &
  VP=$!; sleep 1.5
  afplay -t 10 "$MUSIC" &
  "$B/dualrec" --seconds 9 --out "$OUT/dual_${T}_${BUF}.wav" > /dev/null 2>&1
  wait $VP
  echo "target=$T buffer=$BUF $(grep -o 'underruns=[0-9]*' "$OUT/b_${T}_${BUF}.log" | tail -1) $(python3 "$(dirname "$0")/latency.py" "$OUT/dual_${T}_${BUF}.wav")"
  sleep 1
done
