#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME"
IW_DIR="$ROOT/immortalwrt"
cd "$IW_DIR"
log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

log "Step3: 自定义插件/包"
mkdir -p package/zz

git_clone_or_pull(){
  url="$1"; dir="$2"
  if [ ! -d "$dir/.git" ]; then
    git clone "$url" "$dir"
  else
    cd "$dir" && git pull --ff-only || true
  fi
}

git_clone_or_pull https://github.com/zzzz0317/kmod-fb-tft-gc9307.git package/zz/kmod-fb-tft-gc9307
git_clone_or_pull https://github.com/zzzz0317/xgp-v3-screen.git package/zz/xgp-v3-screen
git_clone_or_pull https://github.com/asvow/luci-app-tailscale package/luci-app-tailscale
git_clone_or_pull https://github.com/EasyTier/luci-app-easytier.git package/luci-app-easytier
git_clone_or_pull https://github.com/sirpdboy/luci-app-lucky.git package/lucky

log "Step3: 完成"
