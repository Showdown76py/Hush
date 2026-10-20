#!/bin/bash
# Lancé en root par Hush (via la fenêtre d'authentification de macOS).
# Usage : driver-admin.sh install <chemin/vers/Hush.driver>
#         driver-admin.sh uninstall
set -euo pipefail
DST="/Library/Audio/Plug-Ins/HAL/Hush.driver"

restart_coreaudio() {
    launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true
}

case "${1:-}" in
install)
    SRC="${2:?chemin du driver manquant}"
    [ -d "$SRC" ] && [ "$(basename "$SRC")" = "Hush.driver" ] || { echo "driver invalide : $SRC" >&2; exit 2; }
    mkdir -p "/Library/Audio/Plug-Ins/HAL"
    rm -rf "$DST"
    /usr/bin/ditto "$SRC" "$DST"
    chown -R root:wheel "$DST"
    chmod -R go-w "$DST"
    xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
    restart_coreaudio
    ;;
uninstall)
    rm -rf "$DST"
    restart_coreaudio
    ;;
*)
    echo "usage : $0 install <driver> | uninstall" >&2
    exit 2
    ;;
esac
