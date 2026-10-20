#!/bin/bash
# Installe Hush.driver dans /Library/Audio/Plug-Ins/HAL et redémarre coreaudiod.
# Usage : sudo scripts/install-driver.sh [chemin/vers/Hush.driver]
set -euo pipefail
SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/Hush.driver}"
DST="/Library/Audio/Plug-Ins/HAL/Hush.driver"
if [ "$(id -u)" != 0 ]; then echo "Ce script doit être lancé avec sudo." >&2; exit 1; fi
[ -d "$SRC" ] || { echo "Driver introuvable : $SRC" >&2; exit 1; }
rm -rf "$DST"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"
chmod -R go-w "$DST"
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
echo "Hush.driver installé, coreaudiod redémarré."
