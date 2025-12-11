#!/usr/bin/env bash
# 文件名: fix_python_wheel_link.sh
# 功能: 修复 Python Wheel 包名与预期不符的问题 (创建软链接)
# 配置阶段: 300 (在feeds安装后，模块编译前运行)

# 确保遇到错误时立即退出
set -euo pipefail

# 1. 定义路径
# 主脚本在源码根目录执行，所以 $PWD 即为 SOURCE_ROOT
SOURCE_ROOT="$PWD"
# 目标构建目录 (需要根据您的目标架构和包版本调整)
# 🚨 注意: 这里的 target-x86_64_musl 必须与您的编译目标保持一致
BUILD_DIR_BASE="build_dir/target-x86_64_musl" 
PACKAGE_NAME="pypi/Markdown-3.4.4"
SUB_DIR="openwrt-build"

TARGET_DIR="$SOURCE_ROOT/$BUILD_DIR_BASE/$PACKAGE_NAME/$SUB_DIR"

log(){ printf "[%s][WHEEL-FIX] %s\n" "$(date '+%T')" "$*"; }

# 2. 定义文件名
# 源代码中的实际文件名
ACTUAL_FILE="markdown-3.4.4-py3-none-any.whl"
# OpenWrt 编译系统预期的文件名
EXPECTED_FILE="Markdown-3.4.4-py3-none-any.whl"

log "开始: 检查并创建 Python Wheel 包软链接..."
log "目标目录: $TARGET_DIR"

# 3. 检查目录并执行链接操作
if [ -d "$TARGET_DIR" ]; then
    (
        # 切换到目标目录执行操作
        cd "$TARGET_DIR" || exit 1
        
        if [ -f "$ACTUAL_FILE" ]; then
            # 检查是否已存在同名软链接或文件
            if [ ! -f "$EXPECTED_FILE" ] || [ ! -L "$EXPECTED_FILE" ]; then
                # 执行核心操作：创建软链接
                ln -sf "$ACTUAL_FILE" "$EXPECTED_FILE"
                log "✅ 成功创建软链接: $EXPECTED_FILE -> $ACTUAL_FILE"
            else
                log "⚠️ 软链接或目标文件已存在，跳过创建。"
            fi
        else
            log "❌ 错误: 原始 Wheel 文件未找到 ($ACTUAL_FILE)，无法创建链接。"
            # 通常不需要在这里退出，因为可能其他架构或包类型不需要这个链接
        fi
    )
    log "完成: Python Wheel 软链接修复。"
else
    log "⚠️ 警告: 目标构建目录不存在 ($TARGET_DIR)。跳过修复。"
fi
