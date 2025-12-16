#!/usr/bin/env bash
# 文件名: inject_autorun_a.sh
# 功能: 编译后注入首次启动配置 (解决 DHCP 失效问题版)
# 机制: 使用 /etc/uci-defaults 替代 rc.local
# 配置阶段: 850

set -euo pipefail

# --- 1. 脚本设置 ---
TARGET_IP="10.0.11.1" 
TARGET_SSID="ImmortalWrt-Custom"
TARGET_KEY="custompassword" 
TARGET_COUNTRY="CN"         

RADIO0_CHANNEL="auto"       
RADIO0_HTMODE="HT20"        

RADIO1_CHANNEL="auto"       
RADIO1_HTMODE="VHT80"       

# --- 2. 内部变量 ---
FILES_DIR="$PWD/files"
# 🌟 关键变更：目标不再是 rc.local，而是 uci-defaults 目录
UCI_DEFAULTS_DIR="$FILES_DIR/etc/uci-defaults"
TARGET_FILE="$UCI_DEFAULTS_DIR/99-custom-setup"

log(){ printf "[%s][AUTORUN-UCI] %s\n" "$(date '+%T')" "$*"; }

log "目标配置 -> IP: $TARGET_IP, SSID: $TARGET_SSID"

# 确保目录存在
mkdir -p "$UCI_DEFAULTS_DIR"

# --- 3. 生成 UCI-Defaults 脚本内容 ---
# 该脚本会在路由器首次启动时执行，执行完毕后系统会自动将其删除
SCRIPT_CONTENT=$(cat << EOF_SCRIPT
#!/bin/sh

# 1. 配置 LAN IP
# uci-defaults 运行较早，此时修改配置，稍后网络服务启动时会自动应用新 IP
uci set network.lan.ipaddr='$TARGET_IP'
uci commit network

# 2. 配置无线 Wi-Fi
# 尝试检测无线硬件
[ ! -f /etc/config/wireless ] && wifi detect > /etc/config/wireless

if [ -f /etc/config/wireless ]; then
    # 启用所有接口并设置国家代码
    for radio in \$(uci show wireless | grep -E '^wireless\.radio.+=(mac80211|cfg80211)' | cut -d'.' -f2); do
        uci set wireless.\$radio.disabled='0'
        uci set wireless.\$radio.country='$TARGET_COUNTRY'
    done
    
    # Radio0 (2.4G)
    uci set wireless.radio0.channel='$RADIO0_CHANNEL'
    uci set wireless.radio0.htmode='$RADIO0_HTMODE'
    uci set wireless.default_radio0.ssid='$TARGET_SSID'
    uci set wireless.default_radio0.encryption='psk2+ccmp'
    uci set wireless.default_radio0.key='$TARGET_KEY'
    uci set wireless.default_radio0.disabled='0'
    
    # Radio1 (5G)
    if uci get wireless.radio1 >/dev/null 2>&1; then
         uci set wireless.radio1.channel='$RADIO1_CHANNEL'
         uci set wireless.radio1.htmode='$RADIO1_HTMODE'
         uci set wireless.default_radio1.ssid='$TARGET_SSID'_5G
         uci set wireless.default_radio1.encryption='psk2+ccmp'
         uci set wireless.default_radio1.key='$TARGET_KEY'
         uci set wireless.default_radio1.disabled='0'
    fi
    
    uci commit wireless
fi

# 3. 强制生效逻辑
# 虽然 uci-defaults 通常不需要重启服务，但为了确保万无一失（特别是 wifi），我们显式重启相关服务
/etc/init.d/network reload
/etc/init.d/dnsmasq reload
/etc/init.d/firewall reload

# 如果是首次检测生成的 wifi 配置，有时需要显式 wifi reload
wifi reload

# 退出码 0 告诉系统脚本执行成功，系统会自动删除此文件 (/etc/uci-defaults/99-custom-setup)
exit 0
EOF_SCRIPT
)

# --- 4. 写入文件 ---
log "正在生成 uci-defaults 脚本: $TARGET_FILE ..."
echo "$SCRIPT_CONTENT" > "$TARGET_FILE"
chmod +x "$TARGET_FILE"

log "注入完成。脚本将在首次启动时运行并自动配置网络。"
exit 0
