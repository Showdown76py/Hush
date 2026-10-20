#!/bin/bash
# Qualité de la voix : 4 prises de 6 s (brut, VP, VP sans AGC, VP + musique) pendant que l'on parle.
# Usage : voice_quality_test.sh <musique> <dossier>
set -eu
MUSIC="$1"; OUT="$2"
B="$(dirname "$0")/../.build/debug/vpcapture"
mkdir -p "$OUT"
say -v Thomas "Test de la voix. Parlez normalement, sans vous arrêter, jusqu'au signal de fin."
sleep 0.5
"$B" --raw --seconds 6 --out "$OUT/1_brut.wav" > /dev/null
"$B" --seconds 6 --out "$OUT/2_vp.wav" > /dev/null
"$B" --seconds 6 --prop 2101=0 --out "$OUT/3_vp_sans_agc.wav" > /dev/null
afplay -t 8 "$MUSIC" &
sleep 0.5
"$B" --seconds 6 --out "$OUT/4_vp_musique.wav" > /dev/null
wait
say -v Thomas "Terminé, merci."
