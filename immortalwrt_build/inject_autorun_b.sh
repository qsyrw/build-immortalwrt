#!/usr/bin/env bash
# 文件名: inject_autorun_b.sh
# 功能: 编译后自动注入首次启动脚本，仅修改 LAN IP。
# 配置阶段: 850
# 修改IP方法: sed -i 's#192.168.1.1#10.0.0.1#g' ~/immortalwrt_builder_root/custom_scripts/inject_autorun_b.sh

set -euo pipefail

# --- 1. 配置区 (占位符) ---
# 您可以使用 sed 命令在编译前动态修改这个 IP
TARGET_IP="192.168.1.1" 

# --- 2. 内部变量 ---
# 主脚本已切换到源码目录，直接使用 PWD
FILES_DIR="$PWD/files"
RC_LOCAL_PATH="$FILES_DIR/etc/rc.local"

log(){ printf "[%s][AUTORUN-B] %s\n" "$(date '+%T')" "$*"; }

log "目标配置 -> LAN IP: $TARGET_IP"

# 确保目录存在
mkdir -p "$FILES_DIR/etc"

# 如果 rc.local 不存在，创建一个标准的 OpenWrt 启动脚本模板
if [ ! -f "$RC_LOCAL_PATH" ]; then
    log "rc.local 不存在，创建新文件..."
    echo "# Put your custom commands here that should be executed once" > "$RC_LOCAL_PATH"
    echo "# the system init finished. By default this file does nothing." >> "$RC_LOCAL_PATH"
    echo "" >> "$RC_LOCAL_PATH"
    echo "exit 0" >> "$RC_LOCAL_PATH"
    chmod +x "$RC_LOCAL_PATH"
fi

# --- 3. 生成核心逻辑 ---
SCRIPT_CONTENT=$(cat << EOF_SCRIPT
# === BEGIN_AUTORUN_B: $TARGET_IP ===
# 首次启动时仅修改 LAN IP
if [ -f /etc/config/network ]; then 
    /sbin/uci set network.lan.ipaddr='$TARGET_IP'; 
    /sbin/uci commit network; 
    /sbin/service network reload; 
fi

# 自我清理：删除注入块，确保只运行一次
/bin/sed -i '/BEGIN_AUTORUN_B/,/END_AUTORUN_B/d' /etc/rc.local
# === END_AUTORUN_B ===
EOF_SCRIPT
)

# --- 4. 执行注入 (文件追加模式) ---
log "正在向 $RC_LOCAL_PATH 注入脚本..."

# A. 删除文件末尾可能存在的 exit 0
sed -i '/^exit 0/d' "$RC_LOCAL_PATH"

# B. 将脚本内容追加到文件末尾
echo "$SCRIPT_CONTENT" >> "$RC_LOCAL_PATH"

# C. 重新在末尾添加 exit 0
echo "" >> "$RC_LOCAL_PATH"
echo "exit 0" >> "$RC_LOCAL_PATH"

log "注入完成。"
exit 0
