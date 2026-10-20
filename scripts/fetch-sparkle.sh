#!/bin/bash
# downloads sparkle (framework + release tools) and checks its sha256
set -euo pipefail
VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# extracted outside the repo, Vendor/Sparkle is just a symlink. in a synced folder (file provider
# icloud drive) macOS adds xattrs to bundles that codesign rejects
CACHE="${HUSH_VENDOR_CACHE:-$HOME/Library/Caches/io.github.showdown76py.Hush}"
DEST="$CACHE/Sparkle-$VERSION"
mkdir -p "$ROOT/Vendor"
ln -sfn "$DEST" "$ROOT/Vendor/Sparkle"
if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ]; then exit 0; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
echo "$SHA256  $TMP/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xf "$TMP/sparkle.tar.xz" -C "$DEST" Sparkle.framework bin LICENSE
xattr -cr "$DEST" 2>/dev/null || true
echo "$VERSION" > "$DEST/.version"
echo "Sparkle $VERSION -> $DEST"
