#!/usr/bin/env bash
# 文件名: inject_autorun_a.sh
# 功能: 编译后自动注入首次启动脚本 (修复 sed 语法错误版)
# 配置阶段: 850

set -euo pipefail

# --- 1. 脚本设置 (请确认这里是您想要的配置) ---
TARGET_IP="10.0.11.1" 
TARGET_SSID="ImmortalWrt-Custom"
TARGET_KEY="12345678" 
TARGET_COUNTRY="CN"         # 必须设置国家代码

RADIO0_CHANNEL="auto"       
RADIO0_HTMODE="HT20"        

RADIO1_CHANNEL="auto"       
RADIO1_HTMODE="VHT80"       

# --- 2. 内部变量 ---
FILES_DIR="$PWD/files"
RC_LOCAL_PATH="$FILES_DIR/etc/rc.local"

log(){ printf "[%s][AUTORUN-FIX] %s\n" "$(date '+%T')" "$*"; }

log "目标配置 -> IP: $TARGET_IP, SSID: $TARGET_SSID, Country: $TARGET_COUNTRY"

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

# --- 3. 生成要注入的核心逻辑 ---
SCRIPT_CONTENT=$(cat << EOF_SCRIPT
# === BEGIN_AUTORUN_A: $TARGET_IP ===
# 1. 配置 LAN IP
if [ -f /etc/config/network ]; then 
    /sbin/uci set network.lan.ipaddr='$TARGET_IP'; 
    /sbin/uci commit network; 
    /sbin/service network reload;
fi

# 2. 配置无线 Wi-Fi
# 强制生成配置 (如果缺失)
if [ ! -f /etc/config/wireless ]; then
    /sbin/wifi detect > /etc/config/wireless 2>/dev/null
fi

if [ -f /etc/config/wireless ]; then
    # 启用所有接口并设置国家代码
    for radio in \$(/sbin/uci show wireless | grep -E '^wireless\.radio.+=(mac80211|cfg80211)' | cut -d'.' -f2); do
        /sbin/uci set wireless.\$radio.disabled='0';
        /sbin/uci set wireless.\$radio.country='$TARGET_COUNTRY'; 
    done
    
    # Radio0 (2.4G)
    /sbin/uci set wireless.radio0.channel='$RADIO0_CHANNEL'; 
    /sbin/uci set wireless.radio0.htmode='$RADIO0_HTMODE'; 
    /sbin/uci set wireless.default_radio0.ssid='$TARGET_SSID'; 
    /sbin/uci set wireless.default_radio0.encryption='psk2+ccmp'; 
    /sbin/uci set wireless.default_radio0.key='$TARGET_KEY'; 
    /sbin/uci set wireless.default_radio0.disabled='0';
    
    # Radio1 (5G) - 仅当存在时配置
    if /sbin/uci get wireless.radio1 &>/dev/null; then
         /sbin/uci set wireless.radio1.channel='$RADIO1_CHANNEL'; 
         /sbin/uci set wireless.radio1.htmode='$RADIO1_HTMODE'; 
         /sbin/uci set wireless.default_radio1.ssid='$TARGET_SSID'\_5G; 
         /sbin/uci set wireless.default_radio1.encryption='psk2+ccmp'; 
         /sbin/uci set wireless.default_radio1.key='$TARGET_KEY'; 
         /sbin/uci set wireless.default_radio1.disabled='0';
    fi
    
    /sbin/uci commit wireless; 
    /sbin/wifi; 
fi

# 自我清理
/bin/sed -i '/BEGIN_AUTORUN_A/,/END_AUTORUN_A/d' /etc/rc.local
# === END_AUTORUN_A ===
EOF_SCRIPT
)

# --- 4. 执行注入 (使用稳健的文件追加模式) ---
log "正在向 $RC_LOCAL_PATH 注入脚本..."

# A. 删除文件末尾可能存在的 exit 0 (防止脚本提前退出)
sed -i '/^exit 0/d' "$RC_LOCAL_PATH"

# B. 将我们的脚本内容追加到文件末尾
echo "$SCRIPT_CONTENT" >> "$RC_LOCAL_PATH"

# C. 重新在末尾添加 exit 0
echo "" >> "$RC_LOCAL_PATH"
echo "exit 0" >> "$RC_LOCAL_PATH"

log "注入完成。内容已追加到 rc.local 末尾。"
exit 0
