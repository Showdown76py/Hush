#!/bin/bash
# Construit Hush.driver (universal arm64 + x86_64) dans <outdir> (par défaut ../build).
# Usage : build.sh [outdir] [version] [build]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../build}"
VERSION="${2:-0.1.0}"
BUILD="${3:-1}"
B="$OUT/Hush.driver/Contents"
rm -rf "$OUT/Hush.driver"
mkdir -p "$B/MacOS" "$B/Resources"
sed -e "s/\$(MARKETING_VERSION)/$VERSION/" -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD/" "$HERE/Info.plist" > "$B/Info.plist"
clang -bundle -O2 -Wall -Wextra -Werror -std=c11 \
  -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -fvisibility=hidden -I "$HERE/../Shared" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$B/MacOS/Hush" "$HERE/HushDriver.c"
codesign --force --sign "${CODESIGN_IDENTITY:--}" ${CODESIGN_FLAGS:-} "$OUT/Hush.driver"
echo "$OUT/Hush.driver"
