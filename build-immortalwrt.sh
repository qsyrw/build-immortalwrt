#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME"
IW_DIR="$ROOT/immortalwrt"
BUILD_LOG="$ROOT/immortalwrt-build.log"
NUMJOBS="$(nproc || echo 4)"

echo "=== ImmortalWrt Auto Build V1.0.0 ==="
echo "工作目录: $ROOT"
echo "ImmortalWrt 路径: $IW_DIR"
echo "日志文件: $BUILD_LOG"

log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

# Step0~Step7 执行
bash "$ROOT/immortalwrt_build_steps/step0_prepare.sh"
bash "$ROOT/immortalwrt_build_steps/step1_feeds.sh"
bash "$ROOT/immortalwrt_build_steps/step2_fix_odhcp.sh"
bash "$ROOT/immortalwrt_build_steps/step3_custom_packages.sh"
bash "$ROOT/immortalwrt_build_steps/step4_files_setup.sh"
bash "$ROOT/immortalwrt_build_steps/step5_qmodem_config.sh"
bash "$ROOT/immortalwrt_build_steps/step6_runtime_optimize.sh"
bash "$ROOT/immortalwrt_build_steps/step7_fan_control.sh"

cd "$IW_DIR"
if [ ! -f "$IW_DIR/.config" ]; then
    log ".config 不存在; 使用 make defconfig 创建默认配置"
    make defconfig
else
    log ".config 已存在; 使用现有配置"
fi

log "开始下载和编译; 日志 -> $BUILD_LOG"
set +e
make download -j"$NUMJOBS" V=s 2>&1 | tee "$BUILD_LOG"
make -j"$NUMJOBS" V=s 2>&1 | tee -a "$BUILD_LOG"
ret=$?
set -e

if [ $ret -ne 0 ]; then
    log "BUILD 失败 (exit $ret). 日志中首个 'error:' 为:"
    grep -n -m1 -i "error:" "$BUILD_LOG" || true
    exit 1
fi

log "BUILD 成功"
exit 0
