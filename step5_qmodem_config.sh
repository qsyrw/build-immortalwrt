#!/usr/bin/env bash
set -euo pipefail
FILES="$HOME/immortalwrt/files"
log(){ printf "%s %s\n" "$(date '+%F %T')" "$*"; }

log "Step5: QModem 配置及跨升级保留"
cat > "$FILES/lib/upgrade/keep.d/zz-qmodem" <<'EOF'
etc/config/qmodem
etc/zz_build_id
EOF
