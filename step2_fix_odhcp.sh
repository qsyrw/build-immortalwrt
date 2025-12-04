#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME"
IW_DIR="$ROOT/immortalwrt"
cd "$IW_DIR"
log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

log "Step2: 固定 odhcpd / odhcp6c 版本"
fix_makefile() {
  file="$1"; date="$2"; ver="$3"; hash="$4"
  if [ -f "$file" ]; then
    sed -i "s/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=$date/" "$file" || true
    sed -i "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=$ver/" "$file" || true
    sed -i "s/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=$hash/" "$file" || true
  fi
}

fix_makefile package/network/services/odhcpd/Makefile 2025-10-26 fc27940fe9939f99aeb988d021c7edfa54460123 acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a
fix_makefile package/network/ipv6/odhcp6c/Makefile 2025-10-21 77e1ae21e67f81840024ffe5bb7cf69a8fb0d2f0 78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd15462035de46837b

log "Step2: 完成"
