#!/bin/bash
# Usage : build.sh <dossier install de webrtc-audio-processing> [sortie]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="${1:?install webrtc}"
OUT="${2:-$HERE/aec3cap}"
INC="$W/include/webrtc-audio-processing-2"
SRC="$W/../webrtc-audio-processing-2.1/webrtc"
clang++ -std=c++17 -O2 -c "$HERE/aec3_wrap.cc" -I "$INC" -I "$SRC" -I "$W/include" -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_APM_DEBUG_DUMP=0 -o /tmp/aec3_wrap.o
clang -std=c11 -O2 -fobjc-arc -c "$HERE/tap.m" -o /tmp/aec3_tap.o
clang -std=c11 -O2 -c "$HERE/aec3cap.c" -I "$HERE/../../Shared" -o /tmp/aec3cap.o
ABSL=$(find "$W/../webrtc-audio-processing-2.1/build/subprojects" -name "libabsl_*.a" | tr '\n' ' ')
clang++ -O2 /tmp/aec3cap.o /tmp/aec3_wrap.o /tmp/aec3_tap.o "$W/lib/libwebrtc-audio-processing-2.a" $ABSL \
  -framework CoreAudio -framework AudioToolbox -framework CoreFoundation -framework Foundation -o "$OUT"
clang -std=c11 -O2 -c "$HERE/aec3offline.c" -o /tmp/aec3offline.o
clang++ -O2 /tmp/aec3offline.o /tmp/aec3_wrap.o "$W/lib/libwebrtc-audio-processing-2.a" $ABSL -framework CoreFoundation -framework Foundation -o "${OUT}-offline"
echo "$OUT"
