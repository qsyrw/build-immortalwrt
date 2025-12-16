#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME"
IW_DIR="$ROOT/immortalwrt"
FILES="$IW_DIR/files"

log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

log "Step6: FIRSTBOOT + 运行期优化 + LuCI动态界面"

# 先确保多级目录存在并可写
mkdir -p "$FILES"/{usr/lib/lua/luci,usr/bin,etc/uci-defaults,etc/init.d,etc/hotplug.d/usb,etc/hotplug.d/pci,lib/upgrade/keep.d}
chmod -R u+rwX "$FILES/usr/lib/lua/luci" "$FILES/usr/bin"

################################
# 6.x.1 FIRSTBOOT 保底配置 + 刷机判定
################################
cat > "$FILES/etc/uci-defaults/99-firstboot-safe" <<'EOF'
#!/bin/sh
# v1.3.0
# FIRSTBOOT 保底 + 运行期优化 + 刷机类型判定
if [ ! -f /etc/config/.firstboot_marker ]; then
  NEW_FLASH=1
  touch /etc/config/.firstboot_marker
else
  NEW_FLASH=0
fi

if [ "$NEW_FLASH" -eq 1 ]; then
  uci batch <<'EOC'
set network.lan=interface
set network.lan.proto='static'
set network.lan.device='br-lan'
set network.lan.ipaddr='10.0.11.1'
set network.lan.netmask='255.255.255.0'
commit network
EOC

  RADIOS="$(uci show wireless 2>/dev/null | grep '=wifi-device' | cut -d. -f2 || true)"
  FIRST_RADIO=""
  for R in $RADIOS; do
    uci set wireless.$R.disabled='0'
    uci set wireless.$R.country='US'
    [ -z "$FIRST_RADIO" ] && FIRST_RADIO="$R"
  done

  if [ -n "$FIRST_RADIO" ]; then
    uci set wireless.$FIRST_RADIO.band='2g'
    uci set wireless.$FIRST_RADIO.channel='auto'
    uci set wireless.$FIRST_RADIO.htmode='HT20'
  fi

  EXIST_IFACES="$(uci show wireless 2>/dev/null | grep '=wifi-iface' | cut -d. -f2 || true)"
  if [ -z "$EXIST_IFACES" ]; then
    IDX=0
    for R in $RADIOS; do
      uci add wireless wifi-iface
      NEW="$(uci show wireless | tail -n1 | cut -d. -f2)"
      uci rename wireless.$NEW="default_radio$IDX"
      uci set wireless.default_radio$IDX.device="$R"
      uci set wireless.default_radio$IDX.mode='ap'
      uci set wireless.default_radio$IDX.network='lan'
      uci set wireless.default_radio$IDX.ssid='zzXGP'
      uci set wireless.default_radio$IDX.encryption='psk2+ccmp'
      uci set wireless.default_radio$IDX.key='88888888'
      IDX=$((IDX+1))
    done
  else
    for IF in $EXIST_IFACES; do
      uci set wireless.$IF.mode='ap'
      uci set wireless.$IF.network='lan'
      uci set wireless.$IF.ssid='zzXGP'
      uci set wireless.$IF.encryption='psk2+ccmp'
      uci set wireless.$IF.key='88888888'
    done
  fi

  uci commit wireless || true
  [ -f /etc/init.d/zz-runtime-optimize ] && /etc/init.d/zz-runtime-optimize enable 2>/dev/null || true
else
  uci set luci.main.lang='zh_cn' 2>/dev/null || true
  uci set luci.main.mediaurlbase='/luci-static/argon' 2>/dev/null || true
  uci commit luci 2>/dev/null || true
fi

exit 0
EOF
chmod +x "$FILES/etc/uci-defaults/99-firstboot-safe"

################################
# 6.x.2 运行期优化服务 (init.d)
################################
cat > "$FILES/etc/init.d/zz-runtime-optimize" <<'EOF'
#!/bin/sh /etc/rc.common
# Provides: zz-runtime-optimize
# Description: Runtime optimization for WiFi, QModem, and mwan3
START=50

USE_PROCD=1

start() {
  logger -t zz-runtime "start"
  procd_open_instance
  procd_set_param command /usr/bin/zz-runtime-optimize.sh
  procd_set_param respawn
  procd_close_instance
}

stop() {
  logger -t zz-runtime "stop"
  return 0
}
EOF
chmod +x "$FILES/etc/init.d/zz-runtime-optimize"

################################
# 6.x.3 运行期优化实际逻辑
################################
cat > "$FILES/usr/bin/zz-runtime-optimize.sh" <<'EOF'
#!/bin/sh
log(){ logger -t zz-runtime "$*"; }

# 等待网络就绪
wait_for_network() {
    timeout=${1:-30}
    while [ $timeout -gt 0 ]; do
        if ubus call network.interface dump >/dev/null 2>&1; then
            return 0
        fi
        timeout=$((timeout-1))
        sleep 1
    done
    return 1
}

# WiFi 最佳信道选择
choose_best_channel(){
    radio="$1"
    band="$(uci -q get wireless.$radio.band || echo '')"
    candidates=""
    case "$band" in
        *2g*|*2.4*) candidates="1 6 11" ;;
        *5g*) candidates="36 40 44 48 149 153 157 161" ;;
        *6g*) candidates="37 1" ;;
        *) candidates="auto" ;;
    esac
    if [ "$candidates" = "auto" ]; then echo "auto"; return 0; fi
    if ! command -v iwinfo >/dev/null 2>&1; then echo "$(echo $candidates | awk '{print $1}')"; return 0; fi
    scan_output="$(iwinfo "$radio" scan 2>/dev/null || true)"
    if [ -z "$scan_output" ]; then echo "$(echo $candidates | awk '{print $1}')"; return 0; fi
    best="" ; bestn=999999
    for ch in $candidates; do
        n=$(echo "$scan_output" | grep -i "Channel: $ch" | wc -l)
        if [ "$n" -lt "$bestn" ]; then bestn="$n"; best="$ch"; fi
    done
    if [ -z "$best" ]; then echo "$(echo $candidates | awk '{print $1}')"; else echo "$best"; fi
}

# USB/PCIE QModem 枚举
detect_qmodem_slots(){
    for d in /sys/bus/usb/devices/*; do
        [ -d "$d" ] || continue
        if ls "$d"/driver 2>/dev/null | grep -q . 2>/dev/null || ls "$d"/*/* 2>/dev/null | grep -q "tty" 2>/dev/null; then
            port="$(basename "$d")"
            if ! uci show qmodem 2>/dev/null | grep -q "slot='$port'"; then
                uci add qmodem modem-slot
                idx=$(uci show qmodem | tail -n1 | cut -d. -f2)
                uci set qmodem.$idx.type='usb'
                uci set qmodem.$idx.slot="$port"
                uci set qmodem.$idx.alias="wwan_$port"
                uci commit qmodem
                log "added qmodem usb slot $port"
            fi
        fi
    done

    for p in /sys/bus/pci/devices/*; do
        [ -d "$p" ] || continue
        addr="$(basename "$p")"
        vend="$(cat "$p/vendor" 2>/dev/null || true)"
        if [ -n "$vend" ]; then
            if ! uci show qmodem 2>/dev/null | grep -q "slot='$addr'"; then
                uci add qmodem modem-slot
                idx=$(uci show qmodem | tail -n1 | cut -d. -f2)
                uci set qmodem.$idx.type='pcie'
                uci set qmodem.$idx.slot="$addr"
                uci set qmodem.$idx.alias="mpcie_$addr"
                uci commit qmodem
                log "added qmodem pcie slot $addr"
            fi
        fi
    done
}

# WiFi 调优
apply_wifi_tuning(){
    if ! command -v iwinfo >/dev/null 2>&1; then log "iwinfo not present; skipping wifi tuning"; return 0; fi
    for radio in $(uci show wireless 2>/dev/null | grep "=wifi-device" | cut -d. -f2); do
        uci set wireless.$radio.disabled='0' || true
        best=$(choose_best_channel "$radio")
        [ -n "$best" ] && uci set wireless.$radio.channel="$best"
        log "radio $radio best channel: $best"
    done
    uci commit wireless || true
    command -v wifi >/dev/null 2>&1 && (wifi reload || wifi up || true)
}

# 确保 mwan3 policy 映射
ensure_mwan3_policy(){
    if ! uci show mwan3 >/dev/null 2>&1; then log "mwan3 not present; skipping policy mapping"; return 0; fi
    for sec in $(uci show qmodem 2>/dev/null | cut -d. -f2 | sort -u); do
        if [ "$(uci -q get qmodem.$sec.type)" = "usb" ] || [ "$(uci -q get qmodem.$sec.type)" = "pcie" ]; then
            iface_name="if_$sec"
            if ! uci -q get mwan3.$iface_name >/dev/null 2>&1; then
                uci set mwan3.$iface_name='interface'
                uci set mwan3.$iface_name.enabled='1'
                uci set mwan3.$iface_name.proto='dhcp'
                uci commit mwan3
                log "mwan3 interface $iface_name created for qmodem.$sec"
            fi
        fi
    done

    if ! uci -q get mwan3.policy_balanced >/dev/null 2>&1; then
        uci add mwan3 policy
        uci set mwan3.@policy[-1].name='balanced'
        idx=0
        for member in $(uci show mwan3 2>/dev/null | grep ".interface=" | cut -d. -f2); do
            [ $idx -ge 8 ] && break
            uci add mwan3 member
            uci set mwan3.@member[-1].interface=$member
            uci set mwan3.@member[-1].metric='1'
            uci set mwan3.@member[-1].weight='1'
            idx=$((idx+1))
        done
        uci commit mwan3
        log "mwan3 policy_balanced created"
    fi
}

log "zz-runtime: waiting for network"
wait_for_network 30 || log "network daemon not detected early; continuing"
sleep 3
log "zz-runtime: detecting qmodem slots"
detect_qmodem_slots
log "zz-runtime: applying wifi tuning"
apply_wifi_tuning
log "zz-runtime: ensuring mwan3 policy mapping"
ensure_mwan3_policy
log "zz-runtime: done"
EOF
chmod +x "$FILES/usr/bin/zz-runtime-optimize.sh"

################################
# 6.x.5 LuCI骨架动态状态界面
################################
LUCI_DIR="$FILES/usr/lib/lua/luci"
mkdir -p "$LUCI_DIR"/{controller,model/cbi/zz_runtime_optimize,view/zz_runtime_optimize}
chmod -R u+rwX "$LUCI_DIR"

# 控制器
cat > "$LUCI_DIR/controller/zz_runtime_optimize.lua" <<'EOF'
module("luci.controller.zz_runtime_optimize", package.seeall)
function index()
  entry({"admin","system","runtime_optimize"}, cbi("zz_runtime_optimize/main"), _("运行时优化"), 50).dependent = true
end
EOF
chmod 644 "$LUCI_DIR/controller/zz_runtime_optimize.lua"

# CBI模型
cat > "$LUCI_DIR/model/cbi/zz_runtime_optimize/main.lua" <<'EOF'
local uci = require "luci.model.uci".cursor()
local m = Map("zz_runtime_optimize", "运行时优化状态")

-- 概览占位
local s = m:section(SimpleSection, "概览")
s.description = "此页面为运行时优化骨架页，当前展示的是安全占位信息。"

-- WiFi 状态
local t = m:section(SimpleSection, "WiFi 状态")
t.template = "zz_runtime_optimize/wifi_status"

-- QModem 状态
local q = m:section(SimpleSection, "QModem 状态")
q.template = "zz_runtime_optimize/qmodem_status"

return m
EOF
chmod 644 "$LUCI_DIR/model/cbi/zz_runtime_optimize/main.lua"

# WiFi模板
cat > "$LUCI_DIR/view/zz_runtime_optimize/wifi_status.htm" <<'EOF'
<h3>WiFi 运行状态</h3>
<ul>
<%
  local uci = require "luci.model.uci".cursor()
  local radios = {}
  pcall(function()
    uci:foreach("wireless","wifi-device",function(s) radios[#radios+1]=s end)
  end)
  if #radios==0 then
%>
<li>未检测到 wireless 配置（或固件未安装相关包）。</li>
<%
  else
    for _, r in ipairs(radios) do
      local name = r[".name"] or "(unknown)"
      local band = uci:get("wireless", name, "band") or "未知"
      local channel = uci:get("wireless", name, "channel") or "未知"
%>
<li><strong><%= name %></strong> — 频段: <%= band %>; 信道: <%= channel %></li>
<%
    end
  end
%>
</ul>
EOF
chmod 644 "$LUCI_DIR/view/zz_runtime_optimize/wifi_status.htm"

# QModem模板
cat > "$LUCI_DIR/view/zz_runtime_optimize/qmodem_status.htm" <<'EOF'
<h3>QModem 插槽状态</h3>
<ul>
<%
  local uci = require "luci.model.uci".cursor()
  local slots = {}
  pcall(function()
    uci:foreach("qmodem","modem-slot",function(s) slots[#slots+1]=s end)
  end)
  if #slots==0 then
%>
<li>未检测到 qmodem 配置（可能未安装 qmodem 包或尚未识别任何设备）。</li>
<%
  else
    for _, s in ipairs(slots) do
      local id = s[".name"] or "(unknown)"
      local typ = uci:get("qmodem", id, "type") or "未知"
      local alias = uci:get("qmodem", id, "alias") or "未命名"
%>
<li><strong><%= id %></strong> — 类型: <%= typ %>; 别名: <%= alias %></li>
<%
    end
  end
%>
</ul>
EOF
chmod 644 "$LUCI_DIR/view/zz_runtime_optimize/qmodem_status.htm"

################################
# 6.x.6 自动启用运行期优化服务
################################
cat > "$FILES/etc/uci-defaults/97-enable-runtime" <<'EOF'
#!/bin/sh
# 自动启用 zz-runtime-optimize 服务
if [ -f /etc/init.d/zz-runtime-optimize ]; then
  /etc/init.d/zz-runtime-optimize enable 2>/dev/null || true
  /etc/init.d/zz-runtime-optimize start 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$FILES/etc/uci-defaults/97-enable-runtime"

################################
# 6.x.7 FIRSTBOOT 保底配置
################################
cat > "$FILES/etc/uci-defaults/99-firstboot-safe" <<'EOF'
#!/bin/sh
# v1.4.0
# FIRSTBOOT 保底 + 网络/WiFi/QModem 运行期优化
FIRSTBOOT_MARKER="/etc/config/.firstboot_marker"

if [ ! -f "$FIRSTBOOT_MARKER" ]; then
  touch "$FIRSTBOOT_MARKER"
  # 固定 LAN
  uci batch <<'EOC'
set network.lan=interface
set network.lan.proto='static'
set network.lan.device='br-lan'
set network.lan.ipaddr='10.0.11.1'
set network.lan.netmask='255.255.255.0'
commit network
EOC

  # 启用无线设备，设置 2.4GHz HT20
  RADIOS="$(uci show wireless 2>/dev/null | grep '=wifi-device' | cut -d. -f2 || true)"
  FIRST_RADIO=""
  for R in $RADIOS; do
    uci set wireless.$R.disabled='0'
    [ -z "$FIRST_RADIO" ] && FIRST_RADIO="$R"
  done
  if [ -n "$FIRST_RADIO" ]; then
    uci set wireless.$FIRST_RADIO.band='2g'
    uci set wireless.$FIRST_RADIO.htmode='HT20'
    uci set wireless.$FIRST_RADIO.channel='auto'
  fi
  uci commit wireless || true

  # 启动运行期优化服务
  [ -f /etc/init.d/zz-runtime-optimize ] && /etc/init.d/zz-runtime-optimize enable 2>/dev/null || true
else
  # 非首次启动，只保证 LuCI 配置语言/主题
  uci set luci.main.lang='zh_cn' 2>/dev/null || true
  uci set luci.main.mediaurlbase='/luci-static/argon' 2>/dev/null || true
  uci commit luci 2>/dev/null || true
fi

exit 0
EOF
chmod +x "$FILES/etc/uci-defaults/99-firstboot-safe"

################################
# 6.x.8 运行期优化脚本 v2
################################
cat > "$FILES/usr/bin/zz-runtime-optimize.sh" <<'EOF'
#!/bin/sh
# zz-runtime-optimize v2
log(){ logger -t zz-runtime "$*"; }

# 等待网络就绪
wait_for_network() {
  timeout=${1:-30}
  while [ $timeout -gt 0 ]; do
    if ubus call network.interface dump >/dev/null 2>&1; then
      return 0
    fi
    timeout=$((timeout-1))
    sleep 1
  done
  return 1
}

# WiFi 信道选择
choose_best_channel(){
  radio="$1"
  band="$(uci -q get wireless.$radio.band || echo '')"
  candidates=""
  case "$band" in
    *2g*|*2.4*) candidates="1 6 11" ;;
    *5g*) candidates="36 40 44 48 149 153 157 161" ;;
    *6g*) candidates="37 1" ;;
    *) candidates="auto" ;;
  esac
  if [ "$candidates" = "auto" ]; then echo "auto"; return 0; fi
  if ! command -v iwinfo >/dev/null 2>&1; then echo "$(echo $candidates | awk '{print $1}')"; return 0; fi
  scan_output="$(iwinfo "$radio" scan 2>/dev/null || true)"
  if [ -z "$scan_output" ]; then echo "$(echo $candidates | awk '{print $1}')"; return 0; fi
  best="" ; bestn=999999
  for ch in $candidates; do
    n=$(echo "$scan_output" | grep -i "Channel: $ch" | wc -l)
    if [ "$n" -lt "$bestn" ]; then bestn="$n"; best="$ch"; fi
  done
  if [ -z "$best" ]; then echo "$(echo $candidates | awk '{print $1}')"; else echo "$best"; fi
}

# 枚举 QModem USB/PCIe 插槽
detect_qmodem_slots(){
  for d in /sys/bus/usb/devices/*; do
    [ -d "$d" ] || continue
    if ls "$d"/driver 2>/dev/null | grep -q . 2>/dev/null || ls "$d"/*/* 2>/dev/null | grep -q "tty" 2>/dev/null; then
      port="$(basename "$d")"
      if ! uci show qmodem 2>/dev/null | grep -q "slot='$port'"; then
        uci add qmodem modem-slot
        idx=$(uci show qmodem | tail -n1 | cut -d. -f2)
        uci set qmodem.$idx.type='usb'
        uci set qmodem.$idx.slot="$port"
        uci set qmodem.$idx.alias="wwan_$port"
        uci commit qmodem
        log "added qmodem usb slot $port"
      fi
    fi
  done
  for p in /sys/bus/pci/devices/*; do
    [ -d "$p" ] || continue
    addr="$(basename "$p")"
    vend="$(cat "$p/vendor" 2>/dev/null || true)"
    if [ -n "$vend" ]; then
      if ! uci show qmodem 2>/dev/null | grep -q "slot='$addr'"; then
        uci add qmodem modem-slot
        idx=$(uci show qmodem | tail -n1 | cut -d. -f2)
        uci set qmodem.$idx.type='pcie'
        uci set qmodem.$idx.slot="$addr"
        uci set qmodem.$idx.alias="mpcie_$addr"
        uci commit qmodem
        log "added qmodem pcie slot $addr"
      fi
    fi
  done
}

# 应用 WiFi 优化
apply_wifi_tuning(){
  if ! command -v iwinfo >/dev/null 2>&1; then log "iwinfo not present; skipping wifi tuning"; return 0; fi
  for radio in $(uci show wireless 2>/dev/null | grep "=wifi-device" | cut -d. -f2); do
    uci set wireless.$radio.disabled='0' || true
    best=$(choose_best_channel "$radio")
    [ -n "$best" ] && uci set wireless.$radio.channel="$best"
    log "radio $radio best channel: $best"
  done
  uci commit wireless || true
  command -v wifi >/dev/null 2>&1 && (wifi reload || wifi up || true)
}

# 确保 mwan3 策略映射
ensure_mwan3_policy(){
  if ! uci show mwan3 >/dev/null 2>&1; then log "mwan3 not present; skipping policy mapping"; return 0; fi
  for sec in $(uci show qmodem 2>/dev/null | cut -d. -f2 | sort -u); do
    if [ "$(uci -q get qmodem.$sec.type)" = "usb" ] || [ "$(uci -q get qmodem.$sec.type)" = "pcie" ]; then
      iface_name="if_$sec"
      if ! uci -q get mwan3.$iface_name >/dev/null 2>&1; then
        uci set mwan3.$iface_name='interface'
        uci set mwan3.$iface_name.enabled='1'
        uci set mwan3.$iface_name.proto='dhcp'
        uci commit mwan3
        log "mwan3 interface $iface_name created for qmodem.$sec"
      fi
    fi
  done
  if ! uci -q get mwan3.policy_balanced >/dev/null 2>&1; then
    uci add mwan3 policy
    uci set mwan3.@policy[-1].name='balanced'
    idx=0
    for member in $(uci show mwan3 2>/dev/null | grep ".interface=" | cut -d. -f2); do
      [ $idx -ge 8 ] && break
      uci add mwan3 member
      uci set mwan3.@member[-1].interface=$member
      uci set mwan3.@member[-1].metric='1'
      uci set mwan3.@member[-1].weight='1'
      idx=$((idx+1))
    done
    uci commit mwan3
    log "mwan3 policy_balanced created"
  fi
}

# ---- 执行流程 ----
log "zz-runtime: waiting for network"
wait_for_network 30 || log "network daemon not detected early; continuing"
sleep 3
log "zz-runtime: detecting qmodem slots"
detect_qmodem_slots
log "zz-runtime: applying wifi tuning"
apply_wifi_tuning
log "zz-runtime: ensuring mwan3 policy mapping"
ensure_mwan3_policy
log "zz-runtime: done"
EOF
chmod +x "$FILES/usr/bin/zz-runtime-optimize.sh"

################################
# 6.x.9 LuCI 动态状态页面 v2
################################
LUCI_DIR="$FILES/usr/lib/lua/luci"
mkdir -p "$LUCI_DIR"/{controller,model/cbi/zz_runtime_optimize,view/zz_runtime_optimize}
chmod -R u+rwX "$LUCI_DIR"

# 控制器
cat > "$LUCI_DIR/controller/zz_runtime_optimize.lua" <<'EOF'
module("luci.controller.zz_runtime_optimize", package.seeall)
function index()
  entry({"admin","system","runtime_optimize"}, cbi("zz_runtime_optimize/main"), _("运行时优化"), 50).dependent = true
end
EOF
chmod 644 "$LUCI_DIR/controller/zz_runtime_optimize.lua"

# CBI模型
cat > "$LUCI_DIR/model/cbi/zz_runtime_optimize/main.lua" <<'EOF'
local uci = require "luci.model.uci".cursor()
local m = Map("zz_runtime_optimize", "运行时优化状态")

local s = m:section(SimpleSection, "概览")
s.description = "此页面展示 zz-runtime 优化服务的运行状态与 QModem 插槽信息"

local t = m:section(SimpleSection, "WiFi 状态")
t.template = "zz_runtime_optimize/wifi_status"

local q = m:section(SimpleSection, "QModem 状态")
q.template = "zz_runtime_optimize/qmodem_status"

return m
EOF
chmod 644 "$LUCI_DIR/model/cbi/zz_runtime_optimize/main.lua"

# WiFi模板
cat > "$LUCI_DIR/view/zz_runtime_optimize/wifi_status.htm" <<'EOF'
<h3>WiFi 运行状态</h3>
<ul>
<%
  local uci = require "luci.model.uci".cursor()
  local radios = {}
  pcall(function()
    uci:foreach("wireless","wifi-device",function(s) radios[#radios+1]=s end)
  end)
  if #radios==0 then
%>
<li>未检测到 wireless 配置。</li>
<%
  else
    for _, r in ipairs(radios) do
      local name = r[".name"] or "(unknown)"
      local band = uci:get("wireless", name, "band") or "未知"
      local channel = uci:get("wireless", name, "channel") or "未知"
%>
<li><strong><%= name %></strong> — 频段: <%= band %>; 信道: <%= channel %></li>
<%
    end
  end
%>
</ul>
EOF
chmod 644 "$LUCI_DIR/view/zz_runtime_optimize/wifi_status.htm"

# QModem模板（带最近更新时间/daemon心跳）
cat > "$LUCI_DIR/view/zz_runtime_optimize/qmodem_status.htm" <<'EOF'
<h3>QModem 插槽状态</h3>
<ul>
<%
  local uci = require "luci.model.uci".cursor()
  local slots = {}
  local now = os.time()
  pcall(function()
    uci:foreach("qmodem","modem-slot",function(s) slots[#slots+1]=s end)
  end)
  if #slots==0 then
%>
<li>未检测到 qmodem 配置或设备尚未识别。</li>
<%
  else
    for _, s in ipairs(slots) do
      local id = s[".name"] or "(unknown)"
      local typ = uci:get("qmodem", id, "type") or "未知"
      local alias = uci:get("qmodem", id, "alias") or "未命名"
      local ts = tonumber(uci:get("qmodem", id, "last_update") or 0)
      local heartbeat = (now - ts) < 60 and "在线" or "离线"
%>
<li><strong><%= id %></strong> — 类型: <%= typ %>; 别名: <%= alias %>; 状态: <%= heartbeat %>; 最近更新时间: <%= ts > 0 and os.date("%Y-%m-%d %H:%M:%S", ts) or "未知" %></li>
<%
    end
  end
%>
</ul>
EOF
chmod 644 "$LUCI_DIR/view/zz_runtime_optimize/qmodem_status.htm"

################################
# 6.x.10 自动启用 init.d 服务
################################
cat > "$FILES/etc/uci-defaults/97-enable-runtime" <<'EOF'
#!/bin/sh
[ -f /etc/init.d/zz-runtime-optimize ] && /etc/init.d/zz-runtime-optimize enable 2>/dev/null || true
exit 0
EOF
chmod +x "$FILES/etc/uci-defaults/97-enable-runtime"

################################
# 6.x.11 FIRSTBOOT 完整保底配置 v2
################################
cat > "$FILES/etc/uci-defaults/99-firstboot-safe" <<'EOF'
#!/bin/sh
# v2.0.0
# FIRSTBOOT 保底 + 运行期优化 + 刷机类型判定 + LuCI 状态页面支持

FIRSTBOOT_MARKER="/etc/config/.firstboot_marker"

if [ ! -f "$FIRSTBOOT_MARKER" ]; then
  NEW_FLASH=1
  touch "$FIRSTBOOT_MARKER"
else
  NEW_FLASH=0
fi

if [ "$NEW_FLASH" -eq 1 ]; then
  # LAN 静态保底
  uci batch <<'EOC'
set network.lan=interface
set network.lan.proto='static'
set network.lan.device='br-lan'
set network.lan.ipaddr='10.0.11.1'
set network.lan.netmask='255.255.255.0'
commit network
EOC

  # WiFi 启用与 2.4GHz HT20 固定第一个无线设备
  RADIOS="$(uci show wireless 2>/dev/null | grep '=wifi-device' | cut -d. -f2 || true)"
  FIRST_RADIO=""
  for R in $RADIOS; do
    uci set wireless.$R.disabled='0'
    uci set wireless.$R.country='US'
    [ -z "$FIRST_RADIO" ] && FIRST_RADIO="$R"
  done
  if [ -n "$FIRST_RADIO" ]; then
    uci set wireless.$FIRST_RADIO.band='2g'
    uci set wireless.$FIRST_RADIO.channel='auto'
    uci set wireless.$FIRST_RADIO.htmode='HT20'
  fi

  # 自动生成默认无线接口
  EXIST_IFACES="$(uci show wireless 2>/dev/null | grep '=wifi-iface' | cut -d. -f2 || true)"
  if [ -z "$EXIST_IFACES" ]; then
    IDX=0
    for R in $RADIOS; do
      uci add wireless wifi-iface
      NEW="$(uci show wireless | tail -n1 | cut -d. -f2)"
      uci rename wireless.$NEW="default_radio$IDX"
      uci set wireless.default_radio$IDX.device="$R"
      uci set wireless.default_radio$IDX.mode='ap'
      uci set wireless.default_radio$IDX.network='lan'
      uci set wireless.default_radio$IDX.ssid='zzXGP'
      uci set wireless.default_radio$IDX.encryption='psk2+ccmp'
      uci set wireless.default_radio$IDX.key='88888888'
      IDX=$((IDX+1))
    done
  else
    for IF in $EXIST_IFACES; do
      uci set wireless.$IF.mode='ap'
      uci set wireless.$IF.network='lan'
      uci set wireless.$IF.ssid='zzXGP'
      uci set wireless.$IF.encryption='psk2+ccmp'
      uci set wireless.$IF.key='88888888'
    done
  fi

  uci commit wireless || true

  # 启用 runtime 优化服务
  [ -f /etc/init.d/zz-runtime-optimize ] && /etc/init.d/zz-runtime-optimize enable 2>/dev/null || true

else
  # 非首次刷机，确保 LuCI 设置生效
  uci set luci.main.lang='zh_cn' 2>/dev/null || true
  uci set luci.main.mediaurlbase='/luci-static/argon' 2>/dev/null || true
  uci commit luci 2>/dev/null || true
fi

exit 0
EOF
chmod +x "$FILES/etc/uci-defaults/99-firstboot-safe"

log "Step6: 完成，包含 zz-runtime v2 与 LuCI 动态状态页面整合"
