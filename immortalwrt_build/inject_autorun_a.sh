#!/usr/bin/env bash
# 文件名: inject_autorun_a.sh
# 功能: 编译后自动注入首次启动脚本，用于修改 IP、SSID、密码等。
# 配置阶段: 850 (配置导入和修改后，固件生成前)

# 确保遇到错误时立即退出，并捕获管道错误
set -euo pipefail

# --- 脚本设置 (需要根据您的配置调整) ---
# 注意：这些变量通常由主脚本通过配置数组读取，这里是作为注入脚本的模板
TARGET_IP="10.0.11.1" 
TARGET_SSID="ImmortalWrt-Custom"
TARGET_KEY="custompassword" # Wi-Fi 密码
RADIO0_CHANNEL="auto"       # 2.4G 信道
RADIO0_HTMODE="HT20"        # 2.4G 模式
RADIO1_CHANNEL="auto"       # 5G 信道
RADIO1_HTMODE="VHT80"       # 5G 模式

# --- 内部变量 ---
FILES_DIR="$PWD/files" # OpenWrt 源码中用于存放文件的目录
RC_LOCAL_PATH="$FILES_DIR/etc/rc.local"

log(){ printf "[%s][AUTORUN-A-V4] %s\n" "$(date '+%T')" "$*"; }

log "使用配置 -> IP: $TARGET_IP, SSID: $TARGET_SSID"

# 确保 files/etc 目录存在
mkdir -p "$FILES_DIR/etc"

# 检查 rc.local 文件是否存在，如果不存在则创建并赋予执行权限
if [ ! -f "$RC_LOCAL_PATH" ]; then
    echo "#!/bin/sh /etc/rc.common" > "$RC_LOCAL_PATH"
    echo "NO_START=yes" >> "$RC_LOCAL_PATH"
    echo "START=99" >> "$RC_LOCAL_PATH"
    echo "" >> "$RC_LOCAL_PATH"
    echo "boot()" >> "$RC_LOCAL_PATH"
    echo "{" >> "$RC_LOCAL_PATH"
    echo "    # 在这里添加自定义的启动命令" >> "$RC_LOCAL_PATH"
    echo "}" >> "$RC_LOCAL_PATH"
    log "rc.local 文件不存在，创建并赋予执行权限。"
    chmod +x "$RC_LOCAL_PATH"
fi

# 核心注入内容 (使用 EOF 语法写入多行脚本到 rc.local 的 boot() 函数中)
SCRIPT_CONTENT=$(cat << EOF_SCRIPT
# === BEGIN_AUTORUN_A: $TARGET_IP,$TARGET_SSID ===
# 首次启动时修改 LAN IP，并设置无线 SSID/Key/信道/带宽。

# 1. 配置 LAN IP
if [ -f /etc/config/network ]; then 
    /sbin/uci set network.lan.ipaddr='$TARGET_IP'; 
    /sbin/uci commit network; 
    /sbin/service network reload;
    log "LAN IP 已设置为 $TARGET_IP"
fi

# 2. 配置无线 Wi-Fi (优化逻辑 - 解决初次启动无配置的问题)
# 如果 /etc/config/wireless 不存在，则运行 wifi detect 强制生成基础配置文件
if [ ! -f /etc/config/wireless ]; then
    log "警告: /etc/config/wireless 文件缺失，尝试运行 'wifi detect' 生成基础配置。"
    /sbin/wifi detect > /etc/config/wireless 2>/dev/null
    if [ $? -ne 0 ]; then
        log "致命错误: 'wifi detect' 运行失败，无法进行 Wi-Fi 配置。"
    fi
fi

if [ -f /etc/config/wireless ]; then
    log "开始配置无线参数..."
    # 辅助函数：查找并启用所有无线电接口
    # 注意：这里的 \$ 符号用于防止外部 Shell 提前替换变量
    uci_config_wireless() {
        # 查找并启用所有物理无线电接口 (radio0, radio1, etc.)
        for radio in \$(/sbin/uci show wireless | grep -E '^wireless\.radio.+=(mac80211|cfg80211)' | cut -d'.' -f2); do
            /sbin/uci set wireless.\$radio.disabled='0';
            log "已启用物理无线接口: \$radio"
        done
        
        # 针对标准的 radio0 (2.4G)
        /sbin/uci set wireless.radio0.channel='$RADIO0_CHANNEL'; 
        /sbin/uci set wireless.radio0.htmode='$RADIO0_HTMODE'; 
        /sbin/uci set wireless.default_radio0.ssid='$TARGET_SSID'; 
        /sbin/uci set wireless.default_radio0.encryption='psk2+ccmp'; 
        /sbin/uci set wireless.default_radio0.key='$TARGET_KEY'; 
        /sbin/uci set wireless.default_radio0.disabled='0'; # 确保 AP 接口启用
        
        # 针对标准的 radio1 (5G)
        if /sbin/uci get wireless.radio1 &>/dev/null; then
             /sbin/uci set wireless.radio1.channel='$RADIO1_CHANNEL'; 
             /sbin/uci set wireless.radio1.htmode='$RADIO1_HTMODE'; 
             /sbin/uci set wireless.default_radio1.ssid='$TARGET_SSID'\_5G; # 建议 SSID 区分
             /sbin/uci set wireless.default_radio1.encryption='psk2+ccmp'; 
             /sbin/uci set wireless.default_radio1.key='$TARGET_KEY'; 
             /sbin/uci set wireless.default_radio1.disabled='0'; # 确保 AP 接口启用
        else
             log "警告: 未检测到标准的 radio1 接口，跳过 5G 配置。"
        fi
    }
    
    # 执行配置
    uci_config_wireless
    
    /sbin/uci commit wireless; 
    /sbin/wifi; # 重新加载 Wi-Fi 配置
    log "Wi-Fi 配置完成并重启服务。"
fi

# 自我清理：删除包含注入标识的整个块，确保只运行一次
/bin/sed -i '/BEGIN_AUTORUN_A/,/END_AUTORUN_A/d' /etc/rc.local
# === END_AUTORUN_A: $TARGET_IP,$TARGET_SSID ===
EOF_SCRIPT
)

# 注入到 rc.local 的 boot() 函数中
# 使用 sed 在 'boot()' 后面插入内容
log "正在向 $RC_LOCAL_PATH 中注入自启脚本A (IP & 完整 WiFi 配置)..."
sed -i "/^boot()/a\\$SCRIPT_CONTENT" "$RC_LOCAL_PATH"

if [ $? -eq 0 ]; then
    log "注入完成。"
    exit 0
else
    log "错误: 注入失败。"
    exit 1
fi
