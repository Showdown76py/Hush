#!/bin/bash
# builds hush, signs it, wraps it in a dmg and notarizes if possible
#
# usage: ./scripts/release.sh [version]
#
# signing in priority order
#   a) developer id if CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" is set, w/
#      hardened runtime + timestamp. notarize if NOTARY_PROFILE is set
#      (xcrun notarytool store-credentials <profile> --apple-id ... --team-id ...)
#   b) "Hush Self-Signed Code Signing" cert if it's in the keychain
#      (scripts/create-signing-cert.sh). mic permission survives across versions but
#      gatekeeper still asks "Open Anyway" on first install
#   c) ad-hoc otherwise. mic permission re-prompted every version
#
# if sparkle's EdDSA private key is available (keychain or SPARKLE_KEY_FILE) the dmg gets signed and
# build/release/appcast.xml generated. DOWNLOAD_URL_PREFIX = url where the dmg is published
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SELF_SIGNED_NAME="Hush Self-Signed Code Signing"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"; MODE="developer-id"
elif security find-certificate -c "$SELF_SIGNED_NAME" >/dev/null 2>&1; then
    IDENTITY="$SELF_SIGNED_NAME"; MODE="self-signed"
else
    IDENTITY="-"; MODE="ad-hoc"
fi
REPO_URL="${REPO_URL:-https://github.com/Showdown76py/Hush}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-$REPO_URL/releases/download/v$VERSION/}"
OUT="$ROOT/build/release"
DERIVED="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Hush-release}"
SPARKLE_BIN="$ROOT/Vendor/Sparkle/bin"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }

step "Préparation (Hush $VERSION, build $BUILD_NUMBER)"
"$ROOT/scripts/fetch-sparkle.sh"
command -v xcodegen >/dev/null && xcodegen generate --quiet
rm -rf "$OUT"
mkdir -p "$OUT"

# SPARKLE_KEY_FILE in ci, keychain on maintainer's machine
SPARKLE_SIGN=()
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    SPARKLE_SIGN=(--ed-key-file "$SPARKLE_KEY_FILE")
elif "$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1; then
    PROJECT_KEY="$(awk '/SPARKLE_PUBLIC_KEY:/ {print $2; exit}' project.yml | tr -d '"')"
    if [ "$("$SPARKLE_BIN/generate_keys" -p)" != "$PROJECT_KEY" ]; then
        echo "La clé Sparkle du trousseau ne correspond pas à SPARKLE_PUBLIC_KEY (project.yml)." >&2
        exit 1
    fi
    SPARKLE_SIGN=(--keychain-only)
else
    echo "Pas de clé privée Sparkle : l'appcast ne sera pas généré."
fi

step "Build Release universel (arm64 + x86_64)"
xcodebuild -project Hush.xcodeproj -scheme Hush -configuration Release \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_IDENTITY="-" \
    build | (command -v xcbeautify >/dev/null && xcbeautify || grep -E "error: |warning: |\*\* BUILD")
APP_SRC="$DERIVED/Build/Products/Release/Hush.app"
# sign outside the repo. in a synced folder (file provider, icloud drive) macOS adds
# xattrs to bundles that codesign rejects
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Hush.app"
ditto "$APP_SRC" "$APP"
xattr -cr "$APP"
lipo -info "$APP/Contents/MacOS/Hush"
lipo -info "$APP/Contents/Resources/Hush.driver/Contents/MacOS/Hush"

step "Signature : $MODE ($IDENTITY)"
SIGN=(codesign --force --sign "$IDENTITY")
DRIVER_SIGN=(codesign --force --sign "$IDENTITY")
if [ "$MODE" = "developer-id" ]; then
    SIGN+=(--options runtime --timestamp)
    DRIVER_SIGN+=(--options runtime --timestamp)
elif [ "$MODE" = "self-signed" ]; then
    # driver has no permission to keep and coreaudiod accepts ad-hoc
    DRIVER_SIGN=(codesign --force --sign -)
fi
# inside out (no --deep)
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPK/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPK/Autoupdate"
"${SIGN[@]}" "$SPK/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${DRIVER_SIGN[@]}" "$APP/Contents/Resources/Hush.driver"
"${SIGN[@]}" --entitlements "$ROOT/App/Hush.entitlements" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

step "Création du DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Hush.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Hush-$VERSION.dmg"
hdiutil create -quiet -volname "Hush $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
if [ "$MODE" = "developer-id" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

if [ "$MODE" = "developer-id" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    step "Notarisation (profil $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG" || true
elif [ "$MODE" = "developer-id" ]; then
    echo "NOTARY_PROFILE non défini : DMG signé mais non notarisé."
fi

if [ ${#SPARKLE_SIGN[@]} -gt 0 ]; then
    step "Appcast Sparkle"
    if [ "${SPARKLE_SIGN[0]}" = "--keychain-only" ]; then SPARKLE_SIGN=(); fi
    "$SPARKLE_BIN/generate_appcast" ${SPARKLE_SIGN[@]+"${SPARKLE_SIGN[@]}"} \
        --download-url-prefix "$DOWNLOAD_URL_PREFIX" -o "$OUT/appcast.xml" "$OUT"
fi

step "Terminé"
ls -lh "$OUT"
shasum -a 256 "$DMG"
