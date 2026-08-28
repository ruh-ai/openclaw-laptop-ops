#!/usr/bin/env bash
# Shared bash helpers for wsl/*.sh. Sourced, not executed. Runs as WSL_USER unless noted.
set -o pipefail
OPS_REPO="${OPS_REPO:-/mnt/c/openclaw-laptop-ops}"
OPS_SITE_ENV="${OPS_SITE_ENV:-$OPS_REPO/config/site.env}"
[ -f "$OPS_SITE_ENV" ] || OPS_SITE_ENV="$OPS_REPO/config/site.env.example"
# load KEY=VALUE, strip CR and inline comments
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%$'\r'}"; [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
  k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"; v="${v%%[[:space:]]#*}"; v="${v%"${v##*[![:space:]]}"}"; v="${v#\"}"; v="${v%\"}"
  export "$k=$v"
done < "$OPS_SITE_ENV"
: "${GATEWAY_PORT:=18789}"; : "${OPENCLAW_SERVICE:=openclaw-gateway.service}"; : "${OPENCLAW_HOME:=$HOME/.openclaw}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export OPS_HOME="$HOME/.openclaw-ops"
mkdir -p "$OPS_HOME"/{snapshots,repair,logs}
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
log() { local lvl="$1"; shift; printf '%s [%s] %s\n' "$(date -Is)" "$lvl" "$*" | tee -a "$OPS_HOME/logs/ops.log" >&2; }
die() { log ERROR "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
user_systemctl() { systemctl --user "$@"; }
rpc_ok() { timeout 40 openclaw gateway status --require-rpc >/dev/null 2>&1; }
wait_rpc() { # wait_rpc [tries] - service may need 1-2 min after restart before RPC answers
  local tries="${1:-24}" i
  for i in $(seq 1 "$tries"); do port_listening && rpc_ok && return 0; sleep 5; done
  return 1
}
service_state() { user_systemctl is-active "$OPENCLAW_SERVICE" 2>/dev/null || true; }
port_listening() { (exec 3<>/dev/tcp/127.0.0.1/"$GATEWAY_PORT") 2>/dev/null && exec 3>&- && return 0; return 1; }
disk_used_pct() { df -P / | awk 'NR==2{gsub("%","",$5); print $5}'; }
