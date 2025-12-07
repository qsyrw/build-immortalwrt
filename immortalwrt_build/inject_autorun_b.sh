#!/usr/bin/env bash
# 文件名: inject_autorun_b.sh
# 功能: 首次启动时，仅修改 LAN IP。
# 用法: bash inject_autorun_b.sh <目标IP> <源码根目录>

set -euo pipefail

# 1. 参数检查
TARGET_IP="$1"
SOURCE_ROOT="$2"

if [[ -z "$TARGET_IP" || -z "$SOURCE_ROOT" ]]; then
    echo "错误: 缺少参数。用法: bash $0 <目标IP> <源码根目录>"
    exit 1
fi
if [[ ! -d "$SOURCE_ROOT" ]]; then
    echo "错误: 源码目录 [$SOURCE_ROOT] 不存在。"
    exit 1
fi

log(){ printf "[%s][AUTORUN-B] %s\n" "$(date '+%T')" "$*"; }

# 目标文件路径 (在源码树的 Overlay 目录中)
RC_LOCAL_FILE="$SOURCE_ROOT/files/etc/rc.local"
CONFIG_DIR=$(dirname "$RC_LOCAL_FILE")

log "目标 IP: $TARGET_IP"

# 2. 准备 Overlay 目录
mkdir -p "$CONFIG_DIR"
if [ ! -f "$RC_LOCAL_FILE" ]; then
    log "rc.local 文件不存在，创建并赋予执行权限。"
    echo "exit 0" > "$RC_LOCAL_FILE"
    chmod +x "$RC_LOCAL_FILE"
fi

# 3. 注入脚本内容 (核心逻辑)
# 注入 UCI 命令块，该命令块在执行完成后会自我删除。
SCRIPT_CONTENT=$(cat << EOF_SCRIPT
# === BEGIN_AUTORUN_B: $TARGET_IP ===
# 首次启动时仅修改 LAN IP。
if [ -f /etc/config/network ]; then 
    /sbin/uci set network.lan.ipaddr='$TARGET_IP'; 
    /sbin/uci commit network; 
    /sbin/service network restart; 
fi
# 自我清理：删除包含目标 IP 的注入块，确保只运行一次
/bin/sed -i '/BEGIN_AUTORUN_B/d' /etc/rc.local
/bin/sed -i '/END_AUTORUN_B/d' /etc/rc.local
# === END_AUTORUN_B: $TARGET_IP ===
EOF_SCRIPT
)

# 4. 执行注入
log "正在向 $RC_LOCAL_FILE 中注入自启脚本B..."

# 1. 删除原有的 exit 0
sed -i '/^exit 0$/d' "$RC_LOCAL_FILE"

# 2. 插入新的脚本内容
echo -e "$SCRIPT_CONTENT" >> "$RC_LOCAL_FILE"

# 3. 重新添加 exit 0
echo "exit 0" >> "$RC_LOCAL_FILE"

log "注入完成。请在主脚本中配置注入命令。"
