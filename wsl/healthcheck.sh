#!/usr/bin/env bash
# Local health check. `--json` prints one JSON line (consumed by windows/supervisor/HealthCheck.ps1). Exit 0 = service active AND RPC ok.
source "$(dirname "$0")/lib.sh"
pid1=$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')
systemd_ok=false; [ "$pid1" = "systemd" ] && systemd_ok=true
state=$(service_state); active=false; [ "$state" = "active" ] && active=true
rpc=false; detail="skipped"
if have openclaw; then out=$(timeout 40 openclaw gateway status --require-rpc 2>&1); rc=$?; if [ $rc -eq 0 ]; then rpc=true; detail="ok"; else detail="exit $rc: $(echo "$out" | tail -1 | tr -d '"' | cut -c1-160)"; fi; else detail="openclaw not on PATH"; fi
port=false; port_listening && port=true
disk=$(disk_used_pct); ip=$(hostname -I 2>/dev/null | awk '{print $1}')
ver=$(openclaw --version 2>/dev/null | head -1 || echo unknown)
if [ "${1:-}" = "--json" ]; then
  printf '{"ts":"%s","pid1":"%s","systemd":%s,"service_state":"%s","service_active":%s,"rpc_ok":%s,"rpc_detail":"%s","port_listening":%s,"disk_used_pct":%s,"wsl_ip":"%s","openclaw_version":"%s"}\n' \
    "$(date -Is)" "$pid1" "$systemd_ok" "$state" "$active" "$rpc" "$(echo "$detail" | sed 's/"/\\"/g')" "$port" "${disk:-0}" "$ip" "$ver"
else
  echo "pid1=$pid1 systemd=$systemd_ok service=$state rpc=$rpc ($detail) port=$port disk=${disk}% ip=$ip openclaw=$ver"
fi
$active && $rpc
