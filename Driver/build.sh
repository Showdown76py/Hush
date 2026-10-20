#!/bin/bash
# builds Hush.driver (universal arm64 + x86_64) into <outdir> (default ../build)
# usage: build.sh [outdir] [driver version]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../build}"
DRIVER_VERSION="${2:-$(awk '/HUSH_DRIVER_VERSION:/ {print $2; exit}' "$HERE/../project.yml")}"
B="$OUT/Hush.driver/Contents"
rm -rf "$OUT/Hush.driver"
mkdir -p "$B/MacOS" "$B/Resources"
sed -e "s/\$(HUSH_DRIVER_VERSION)/$DRIVER_VERSION/g" "$HERE/Info.plist" > "$B/Info.plist"
clang -bundle -O2 -Wall -Wextra -Werror -std=c11 \
  -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -fvisibility=hidden -I "$HERE/../Shared" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$B/MacOS/Hush" "$HERE/HushDriver.c"
codesign --force --sign "${CODESIGN_IDENTITY:--}" ${CODESIGN_FLAGS:-} "$OUT/Hush.driver"
echo "$OUT/Hush.driver"
