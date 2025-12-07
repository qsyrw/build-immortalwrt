#!/usr/bin/env bash
# 文件名: inject_autorun_a.sh
# 功能: 首次启动时，修改 LAN IP，并完整设置无线设备的 SSID/Key/信道/带宽。
# 用法: bash inject_autorun_a.sh <目标IP> <SSID> <密码> <R0_信道> <R0_带宽模式> <R1_信道> <R1_带宽模式> <源码根目录>

set -euo pipefail

# 1. 参数定义
TARGET_IP="$1"
TARGET_SSID="$2"
TARGET_KEY="$3"
RADIO0_CHANNEL="$4"
RADIO0_HTMODE="$5"
RADIO1_CHANNEL="$6"
RADIO1_HTMODE="$7"
SOURCE_ROOT="$8"

# 1.1. 参数检查
if [[ -z "$TARGET_IP" || -z "$TARGET_SSID" || -z "$TARGET_KEY" || -z "$RADIO0_CHANNEL" || -z "$RADIO0_HTMODE" || -z "$RADIO1_CHANNEL" || -z "$RADIO1_HTMODE" || -z "$SOURCE_ROOT" ]]; then
    echo "错误: 缺少参数。用法: bash $0 <IP> <SSID> <Key> <R0_CH> <R0_MODE> <R1_CH> <R1_MODE> <源码根目录>"
    echo "当前接收到的参数数量: $#"
    exit 1
fi
if [[ ! -d "$SOURCE_ROOT" ]]; then
    echo "错误: 源码目录 [$SOURCE_ROOT] 不存在。"
    exit 1
fi

log(){ printf "[%s][AUTORUN-A-V3] %s\n" "$(date '+%T')" "$*"; }

# 目标文件路径 (在源码树的 files/etc/rc.local)
RC_LOCAL_FILE="$SOURCE_ROOT/files/etc/rc.local"
CONFIG_DIR=$(dirname "$RC_LOCAL_FILE")

log "目标 IP: $TARGET_IP, SSID: $TARGET_SSID"

# 2. 准备 Overlay 目录
mkdir -p "$CONFIG_DIR"
if [ ! -f "$RC_LOCAL_FILE" ]; then
    log "rc.local 文件不存在，创建并赋予执行权限。"
    echo "exit 0" > "$RC_LOCAL_FILE"
    chmod +x "$RC_LOCAL_FILE"
fi

# 3. 注入脚本内容 (核心逻辑)
# 注入 UCI 命令块，使用 sed 进行自我清理。
SCRIPT_CONTENT=$(cat << EOF_SCRIPT
# === BEGIN_AUTORUN_A: $TARGET_IP,$TARGET_SSID ===
# 首次启动时修改 LAN IP，并设置无线 SSID/Key/信道/带宽。
if [ -f /etc/config/network ]; then 
    /sbin/uci set network.lan.ipaddr='$TARGET_IP'; 
    /sbin/uci commit network; 
    /sbin/service network reload;
fi

if [ -f /etc/config/wireless ]; then 
    # --- Radio 0 (2.4G) 配置 ---
    /sbin/uci set wireless.radio0.channel='$RADIO0_CHANNEL'; 
    /sbin/uci set wireless.radio0.htmode='$RADIO0_HTMODE'; 
    /sbin/uci set wireless.default_radio0.ssid='$TARGET_SSID'; 
    /sbin/uci set wireless.default_radio0.encryption='psk2+ccmp'; 
    /sbin/uci set wireless.default_radio0.key='$TARGET_KEY'; 
    
    # --- Radio 1 (5G) 配置 ---
    /sbin/uci set wireless.radio1.channel='$RADIO1_CHANNEL'; 
    /sbin/uci set wireless.radio1.htmode='$RADIO1_HTMODE'; 
    /sbin/uci set wireless.default_radio1.ssid='$TARGET_SSID'; 
    /sbin/uci set wireless.default_radio1.encryption='psk2+ccmp'; 
    /sbin/uci set wireless.default_radio1.key='$TARGET_KEY'; 

    /sbin/uci commit wireless; 
    wifi; # 使用 wifi 命令启动无线
fi

# 自我清理：删除包含注入标识的整个块，确保只运行一次
/bin/sed -i '/BEGIN_AUTORUN_A/,/END_AUTORUN_A/d' /etc/rc.local
# === END_AUTORUN_A: $TARGET_IP,$TARGET_SSID ===
EOF_SCRIPT
)

# 4. 执行注入
log "正在向 $RC_LOCAL_FILE 中注入自启脚本A (IP & 完整 WiFi 配置)..."

# 1. 删除原有的 exit 0
sed -i '/^exit 0$/d' "$RC_LOCAL_FILE"

# 2. 插入新的脚本内容
echo -e "$SCRIPT_CONTENT" >> "$RC_LOCAL_FILE"

# 3. 重新添加 exit 0
echo "exit 0" >> "$RC_LOCAL_FILE"

log "注入完成。"
