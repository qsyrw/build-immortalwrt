#!/usr/bin/env bash
# 文件名: inject_autorun_a.sh (V4.9.34 优化版：无参数，使用硬编码默认值)
# 功能: 首次启动时，修改 LAN IP，并完整设置无线设备的 SSID/Key/信道/带宽。

set -euo pipefail

# ==========================================================
# 🛑 核心定制区：使用硬编码默认值作为占位符
#    您将使用 sed 命令来修改这些值。
# ==========================================================
# 占位符 IP (必须是唯一的，用于 sed 查找)
TARGET_IP="192.168.99.99" 
TARGET_SSID="OpenWrt_Default_SSID"
TARGET_KEY="OpenWrt_Default_Key"
RADIO0_CHANNEL="auto"       # 2.4G 信道
RADIO0_HTMODE="HT40"        # 2.4G 带宽模式 (HT20/HT40)
RADIO1_CHANNEL="auto"       # 5G 信道
RADIO1_HTMODE="VHT80"       # 5G 带宽模式 (VHT20/VHT40/VHT80/VHT160)

# ==========================================================
# 🛑 注意：在 run_custom_injections 中，脚本是在源码根目录执行的
SOURCE_ROOT="$PWD" 

log(){ printf "[%s][AUTORUN-A-V4] %s\n" "$(date '+%T')" "$*"; }

# 目标文件路径 (在源码树的 files/etc/rc.local)
RC_LOCAL_FILE="$SOURCE_ROOT/files/etc/rc.local"
CONFIG_DIR=$(dirname "$RC_LOCAL_FILE")

log "使用配置 -> IP: $TARGET_IP, SSID: $TARGET_SSID"

# 1. 准备 Overlay 目录
mkdir -p "$CONFIG_DIR"
if [ ! -f "$RC_LOCAL_FILE" ]; then
    log "rc.local 文件不存在，创建并赋予执行权限。"
    echo "exit 0" > "$RC_LOCAL_FILE"
    chmod +x "$RC_LOCAL_FILE"
fi

# 2. 注入脚本内容 (核心逻辑)
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

# 3. 执行注入
log "正在向 $RC_LOCAL_FILE 中注入自启脚本A (IP & 完整 WiFi 配置)..."

# 1. 删除原有的 exit 0
sed -i '/^exit 0$/d' "$RC_LOCAL_FILE"

# 2. 插入新的脚本内容
echo -e "$SCRIPT_CONTENT" >> "$RC_LOCAL_FILE"

# 3. 重新添加 exit 0
echo "exit 0" >> "$RC_LOCAL_FILE"

log "注入完成。"
