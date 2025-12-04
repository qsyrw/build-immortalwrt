#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME"
IW_DIR="$ROOT/immortalwrt"
BUILD_LOG="$ROOT/immortalwrt-build.log"
STEPS_DIR="$ROOT/immortalwrt_build_steps"
NUMJOBS="$(nproc || echo 4)"

echo "=== ImmortalWrt Auto Build V1.0.0 ==="
echo "工作目录: $ROOT"
echo "ImmortalWrt 路径: $IW_DIR"
echo "日志文件: $BUILD_LOG"

log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

# 创建步骤目录
mkdir -p "$STEPS_DIR"

# Step 脚本列表
STEPS=(
  step0_prepare.sh
  step1_feeds.sh
  step2_fix_odhcp.sh
  step3_custom_packages.sh
  step4_files_setup.sh
  step5_qmodem_config.sh
  step6_runtime_optimize.sh
  step7_fan_control.sh
)

# 从 Github 拉取每个 Step 脚本并赋予可执行权限
for step in "${STEPS[@]}"; do
    url="https://raw.githubusercontent.com/qsyrw/build-immortalwrt/main/$step"
    log "下载 $step"
    curl -fsSL "$url" -o "$STEPS_DIR/$step"
    chmod +x "$STEPS_DIR/$step"
done

# Step0~Step7 执行
for step in "${STEPS[@]}"; do
    log "执行 $step"
    bash "$STEPS_DIR/$step" >>"$BUILD_LOG" 2>&1
done

# 编译配置处理
cd "$IW_DIR"
if [ ! -f "$IW_DIR/.config" ]; then
    log ".config 不存在; 使用 make defconfig 创建默认配置"
    make defconfig >>"$BUILD_LOG" 2>&1
else
    log ".config 已存在; 使用现有配置"
fi

# 编译
log "开始下载和编译固件; 日志 -> $BUILD_LOG"
set +e
make download -j"$NUMJOBS" V=s >>"$BUILD_LOG" 2>&1
make -j"$NUMJOBS" V=s >>"$BUILD_LOG" 2>&1
ret=$?
set -e

if [ $ret -ne 0 ]; then
    log "BUILD 失败 (exit $ret)，日志中首个 error:"
    grep -n -m1 -i "error:" "$BUILD_LOG" || true
    exit 1
fi

log "BUILD 成功"
exit 0
