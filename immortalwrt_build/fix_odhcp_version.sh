#!/usr/bin/env bash
# 文件名: fix_odhcp_version.sh
# 功能: 检测并固定 odhcpd 和 odhcp6c 的版本信息。
# 用法: 在主脚本的“脚本注入管理”中，配置为：
#       bash fix_odhcp_version.sh "$CURRENT_SOURCE_DIR" 100

# 确保遇到错误时立即退出，并捕获管道错误
set -euo pipefail

# 1. 检查参数：编译源码根目录
SOURCE_ROOT="$1"

# 如果未提供路径，则退出
if [ -z "$SOURCE_ROOT" ]; then
    echo "错误: 未提供编译源码根目录路径作为参数 (\$1)。"
    exit 1
fi
# 如果路径不存在或不是目录，则退出
if [ ! -d "$SOURCE_ROOT" ]; then
    echo "错误: 源码目录 [$SOURCE_ROOT] 不存在。请确认主脚本是否正确传入了 \$CURRENT_SOURCE_DIR。"
    exit 1
fi

log(){ printf "[%s] %s\n" "$(date '+%T')" "$*"; }

log "开始: 检查并固定 odhcpd / odhcp6c 版本..."

# 辅助函数：替换 Makefile 中的版本信息
# 参数: $1=Makefile相对路径, $2=DATE, $3=VERSION, $4=HASH
fix_makefile() {
  local relative_path="$1"
  local date="$2"
  local ver="$3"
  local hash="$4"
  local file="$SOURCE_ROOT/$relative_path"

  if [ -f "$file" ]; then
    log "-> 正在修改: $relative_path"
    # 使用 sed 替换版本信息，确保兼容性
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
fix_makefile package/network/services/odhcpd/Makefile \
    2025-10-26 \
    fc27940fe9939f99aeb988d021c7edfa54460123 \
    acb086731fd7d072ddddc1d5f3bad9377e89a05597ce004d24bd0cdb60586f0a

# --- 3. odhcp6c 配置 ---
fix_makefile package/network/ipv6/odhcp6c/Makefile \
    2025-10-21 \
    77e1ae21e67f81840024ffe5bb7cf69a8fb0d2f0 \
    78f1c2342330da5f6bf08a4be89df1d771661966bbff13bd15462035de46837b

log "完成: odhcp 版本固定。"

