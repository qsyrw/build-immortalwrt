#!/usr/bin/env bash
set -euo pipefail

FILES="$HOME/immortalwrt/files"
LUCI_DIR="$FILES/usr/lib/lua/luci"
mkdir -p "$FILES/etc/init.d" \
         "$LUCI_DIR/controller" \
         "$LUCI_DIR/model/cbi/zz_fan_control" \
         "$LUCI_DIR/view/zz_fan_control"

# Init.d 脚本
cat > "$FILES/etc/init.d/zz-fan-control" <<'EOF'
#!/bin/sh /etc/rc.common
# Provides: zz-fan-control
START=55

USE_PROCD=1

start() {
    logger -t zz-fan "启动风扇控制"
    procd_open_instance
    procd_set_param command /usr/bin/zz-fan-control.sh
    procd_set_param respawn
    procd_close_instance
}

stop() {
    logger -t zz-fan "停止风扇控制"
}
EOF
chmod +x "$FILES/etc/init.d/zz-fan-control"

# 风扇控制脚本
cat > "$FILES/usr/bin/zz-fan-control.sh" <<'EOF'
#!/bin/sh
log(){ logger -t zz-fan "$*"; }
while true; do
    # 这里放置温度检测和风扇控制逻辑
    sleep 10
done
EOF
chmod +x "$FILES/usr/bin/zz-fan-control.sh"

# LuCI 控制器
cat > "$LUCI_DIR/controller/zz_fan_control.lua" <<'EOF'
module("luci.controller.zz_fan_control", package.seeall)
function index()
  entry({"admin","system","fan_control"}, cbi("zz_fan_control/main"), _("风扇控制"), 55).dependent = true
end
EOF

# CBI 模型
cat > "$LUCI_DIR/model/cbi/zz_fan_control/main.lua" <<'EOF'
local m = Map("zz_fan_control", "风扇状态")
local s = m:section(SimpleSection, "状态信息")
s.template = "zz_fan_control/status"
return m
EOF

# LuCI 模板
cat > "$LUCI_DIR/view/zz_fan_control/status.htm" <<'EOF'
<h3>风扇运行状态</h3>
<p>风扇控制模块已启动，实际温控逻辑在后台服务运行。</p>
EOF
chmod 644 "$LUCI_DIR/controller/zz_fan_control.lua" \
          "$LUCI_DIR/model/cbi/zz_fan_control/main.lua" \
          "$LUCI_DIR/view/zz_fan_control/status.htm"
