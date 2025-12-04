#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME"
IW_DIR="$ROOT/immortalwrt"
FILES="$IW_DIR/files"
log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

log "Step4: 准备 files/ 树"
mkdir -p "$FILES/etc" "$FILES/etc/config" "$FILES/etc/uci-defaults" "$FILES/etc/init.d" "$FILES/usr/bin" "$FILES/etc/hotplug.d/usb" "$FILES/etc/hotplug.d/pci" "$FILES/lib/upgrade/keep.d"

if [ -f feeds/qmodem/application/qmodem/files/etc/config/qmodem ]; then
    cp -f feeds/qmodem/application/qmodem/files/etc/config/qmodem "$FILES/etc/config/qmodem"
fi

log "Step4: 完成"
