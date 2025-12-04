#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME"
IW_DIR="$ROOT/immortalwrt"
log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

log "Step0: 准备工作区"
mkdir -p "$ROOT" "$IW_DIR"

if [ ! -d "$IW_DIR/.git" ]; then
    log "克隆 ImmortalWrt..."
    git clone https://github.com/immortalwrt/immortalwrt.git "$IW_DIR"
else
    log "更新 ImmortalWrt"
    cd "$IW_DIR"
    if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
        log "检测到本地修改: 自动 stash"
        git stash save -u "auto-stash-before-build" || true
        git pull --rebase || git pull || true
        git stash pop || true
    else
        git pull --rebase || git pull || true
    fi
fi

log "Step0: 完成"
