#!/usr/bin/env bash
# 文件名: fix_odhcp_version.sh
# 功能: 检测并固定 odhcpd 和 odhcp6c 的版本信息，解决编译时的 Hash 校验错误。
# 配置阶段: 100 (在 feeds 更新之前)

# 确保遇到错误时立即退出，并捕获管道错误
set -euo pipefail

# 1. 初始化和路径检查
# 🌟 修正: 不再依赖命令行参数 $1。直接使用当前工作目录 $PWD。
SOURCE_ROOT="$PWD"

# 检查当前目录是否为有效的源码根目录
if [ ! -d "$SOURCE_ROOT/package" ]; then
    echo "错误: 当前工作目录 [$SOURCE_ROOT] 看起来不是 OpenWrt/ImmortalWrt 源码根目录。"
    exit 1
fi

log(){ printf "[%s][ODHCP-FIX] %s\n" "$(date '+%T')" "$*"; }

log "开始: 检查并固定 odhcpd / odhcp6c 版本 (源码根目录: $SOURCE_ROOT)..."

# 辅助函数：替换 Makefile 中的版本信息
# 参数: $1=Makefile相对路径, $2=DATE, $3=VERSION, $4=HASH
fix_makefile() {
  local relative_path="$1"
  local date="$2"
  local ver="$3"
  local hash="$4"
  # 完整的 Makefile 路径
  local file="$SOURCE_ROOT/$relative_path"

  if [ -f "$file" ]; then
    log "-> 正在修改: $relative_path"
    
    # 使用 sed 替换版本信息，使用 # 作为分隔符以避免与路径中的 / 冲突
    # 替换 PKG_SOURCE_DATE
    sed -i "s/^PKG_SOURCE_DATE:=.*/PKG_SOURCE_DATE:=$date/" "$file" || { log "警告: 修改 PKG_SOURCE_DATE 失败。"; }
    # 替换 PKG_SOURCE_VERSION
    sed -i "s/^PKG_SOURCE_VERSION:=.*/PKG_SOURCE_VERSION:=$ver/" "$file" || { log "警告: 修改 PKG_SOURCE_VERSION 失败。"; }
    # 替换 PKG_MIRROR_HASH
    sed -i "s/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=$hash/" "$file" || { log "警告: 修改 PKG_MIRROR_HASH 失败。"; }
  else
    log "-> 警告: Makefile 未找到 ($relative_path)，可能已移除或路径不匹配，跳过。"
  fi
}

# --- 2. odhcpd 配置 ---
# 目标路径: package/network/services/odhcpd/Makefile
fix_makefile package/network/services/odhcpd/Makefile \
    2025-10-26 \
    fc27940fe9939f99aeb988d021c7edfa54460123 \
    acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a

# --- 3. odhcp6c 配置 ---
# 目标路径: package/network/ipv6/odhcp6c/Makefile
fix_makefile package/network/ipv6/odhcp6c/Makefile \
    2025-10-21 \
    77e1ae21e67f81840024ffe5bb7cf69a8fb0d2f0 \
    78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd15462035de46837b

log "完成: odhcp 版本固定。"
