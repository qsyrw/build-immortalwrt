#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME"
IW_DIR="$ROOT/immortalwrt"
cd "$IW_DIR"
log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

log "Step1: 更新 feeds"
grep -q '^src-git qmodem ' feeds.conf.default 2>/dev/null || \
  echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default

./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds update qmodem || true
./scripts/feeds install -a -p qmodem || true
./scripts/feeds install -a -f -p qmodem || true
