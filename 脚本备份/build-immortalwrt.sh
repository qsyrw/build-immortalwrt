#!/usr/bin/env bash
set -euo pipefail

# build-immortalwrt.sh
# 用法: bash build-immortalwrt.sh [源码目录]
# 默认源码目录: $HOME/immortalwrt

ROOT="$HOME"
SRC_DIR="${1:-$ROOT/immortalwrt}"       # 源码目录，可由命令行传入
BUILD_LOG="$ROOT/immortalwrt-build.log"
NUMJOBS="$(nproc || echo 4)"

echo "=== ImmortalWrt Auto Build V1.0.0 ==="
echo "工作目录: $ROOT"
echo "源码路径: $SRC_DIR"
echo "日志文件: $BUILD_LOG"

log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

# Step0~Step7 执行函数
run_step(){
    step_name="$1"
    step_script="$ROOT/build-immortalwrt/$step_name"
    if [ ! -f "$step_script" ]; then
        log "未找到 $step_name 脚本: $step_script"
        exit 1
    fi
    chmod +x "$step_script"
    log "执行 $step_name"
    bash "$step_script" "$SRC_DIR"
}

# 执行所有步骤
run_step "step0_prepare.sh"
run_step "step1_feeds.sh"
run_step "step2_fix_odhcp.sh"
run_step "step3_custom_packages.sh"
run_step "step4_files_setup.sh"
run_step "step5_qmodem_config.sh"
run_step "step6_runtime_optimize.sh"
run_step "step7_fan_control.sh"

# 检查 .config
cd "$SRC_DIR"
if [ ! -f "$SRC_DIR/.config" ]; then
    log ".config 不存在; 使用 make defconfig 创建默认配置"
    make defconfig
else
    log ".config 已存在; 使用现有配置"
fi

# 下载与编译
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
