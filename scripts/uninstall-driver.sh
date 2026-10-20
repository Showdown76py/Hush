#!/bin/bash
# Retire Hush.driver et redémarre coreaudiod.
# Usage : sudo scripts/uninstall-driver.sh
set -euo pipefail
DST="/Library/Audio/Plug-Ins/HAL/Hush.driver"
if [ "$(id -u)" != 0 ]; then echo "Ce script doit être lancé avec sudo." >&2; exit 1; fi
rm -rf "$DST"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod
echo "Hush.driver désinstallé, coreaudiod redémarré."
