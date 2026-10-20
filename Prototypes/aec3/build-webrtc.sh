#!/bin/bash
# Compile webrtc-audio-processing 2.1 (BSD-3) en statique, avec l'abseil fourni par le projet.
# Usage : build-webrtc.sh <dossier de travail>   → <dossier>/install/{include,lib}
set -euo pipefail
WORK="${1:?dossier de travail}"
SHA256="ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe"
mkdir -p "$WORK"
cd "$WORK"
[ -f wap.tar.xz ] || curl -fsSL -o wap.tar.xz https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz
echo "$SHA256  wap.tar.xz" | shasum -a 256 -c -
rm -rf webrtc-audio-processing-2.1 && tar -xf wap.tar.xz
cd webrtc-audio-processing-2.1
meson setup build --buildtype=release --default-library=static --force-fallback-for=abseil-cpp --prefix="$WORK/install"
ninja -C build install
