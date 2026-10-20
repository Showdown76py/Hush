#!/bin/bash
# Construit, signe, emballe (DMG) et, si possible, notarise Hush.
#
# Usage : ./scripts/release.sh [version]
#
# Deux modes de signature :
#   a) Developer ID — définir CODESIGN_IDENTITY="Developer ID Application: Nom (TEAMID)".
#      Hardened runtime + horodatage. Notarisation si NOTARY_PROFILE est défini
#      (profil créé avec : xcrun notarytool store-credentials <profil> --apple-id … --team-id …).
#   b) Ad-hoc (par défaut, sans compte Apple Developer) — l'app fonctionne, mais Gatekeeper
#      demandera à l'utilisateur d'autoriser l'ouverture (voir README).
#
# Mises à jour Sparkle : si la clé EdDSA existe dans le trousseau (créée une fois avec
# Vendor/Sparkle/bin/generate_keys), le DMG est signé et build/release/appcast.xml est généré.
# DOWNLOAD_URL_PREFIX : URL où le DMG sera publié (par défaut, les releases GitHub).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-$(awk '/MARKETING_VERSION:/ {print $2; exit}' project.yml)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${CODESIGN_IDENTITY:--}"
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

SPARKLE_PUBLIC_KEY=""
if "$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1; then
    SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
    echo "Clé publique Sparkle trouvée : mises à jour automatiques activées."
else
    echo "Pas de clé Sparkle dans le trousseau : mises à jour automatiques désactivées dans ce build."
    echo "  (créez-la une fois avec : $SPARKLE_BIN/generate_keys)"
fi

step "Build Release universel (arm64 + x86_64)"
xcodebuild -project Hush.xcodeproj -scheme Hush -configuration Release \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
    CODE_SIGN_IDENTITY="-" \
    build | (command -v xcbeautify >/dev/null && xcbeautify || grep -E "error: |warning: |\*\* BUILD")
APP_SRC="$DERIVED/Build/Products/Release/Hush.app"
# Signature et assemblage hors du dépôt : dans un dossier synchronisé (iCloud Drive / File Provider),
# macOS ajoute aux bundles des attributs étendus que codesign refuse.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Hush.app"
ditto "$APP_SRC" "$APP"
xattr -cr "$APP"
lipo -info "$APP/Contents/MacOS/Hush"
lipo -info "$APP/Contents/Resources/Hush.driver/Contents/MacOS/Hush"

step "Signature ($([ "$IDENTITY" = "-" ] && echo "ad-hoc" || echo "$IDENTITY"))"
SIGN=(codesign --force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
    SIGN+=(--options runtime --timestamp)
fi
# De l'intérieur vers l'extérieur (pas de --deep).
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPK/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPK/Autoupdate"
"${SIGN[@]}" "$SPK/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP/Contents/Resources/Hush.driver"
"${SIGN[@]}" --entitlements "$ROOT/App/Hush.entitlements" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

step "Création du DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Hush.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Hush-$VERSION.dmg"
hdiutil create -quiet -volname "Hush $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
if [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

if [ "$IDENTITY" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    step "Notarisation (profil $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG" || true
elif [ "$IDENTITY" != "-" ]; then
    echo "NOTARY_PROFILE non défini : DMG signé mais non notarisé."
fi

if [ -n "$SPARKLE_PUBLIC_KEY" ]; then
    step "Appcast Sparkle"
    "$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_URL_PREFIX" -o "$OUT/appcast.xml" "$OUT"
fi

step "Terminé"
ls -lh "$OUT"
shasum -a 256 "$DMG"
