#!/usr/bin/env bash
# Phase 2b — OpenClaw installed (unless OPS_OPENCLAW_INSTALL=existing) and running as a systemd --user service with linger.
# Runs as WSL_USER. Idempotent. Also installs the local health timer (wsl/systemd/*).
source "$(dirname "$0")/lib.sh"
[ "$(id -un)" = "${WSL_USER:-$(id -un)}" ] || die "must run as $WSL_USER (got $(id -un))"
[ "$(ps -p 1 -o comm= | tr -d ' ')" = "systemd" ] || die "systemd is not PID 1 — run windows/20-wsl-prepare.ps1 first"
# user manager must be up (linger); if not, start it via sudo (allowed by sudoers drop-in)
if ! user_systemctl is-system-running >/dev/null 2>&1; then sudo -n loginctl enable-linger "$(id -un)" || true; sudo -n systemctl start "user@$(id -u).service" || true; sleep 3; fi
user_systemctl is-system-running --quiet 2>/dev/null || user_systemctl list-units >/dev/null 2>&1 || die "systemd --user not reachable (XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR). Check linger: loginctl show-user $(id -un)"
loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null | grep -q yes || { sudo -n loginctl enable-linger "$(id -un)" && log INFO "linger enabled"; }

if ! have openclaw; then
  case "${OPS_OPENCLAW_INSTALL:-installer}" in
    existing) die "OPS_OPENCLAW_INSTALL=existing but 'openclaw' not on PATH for $(id -un). Fix PATH or set method to installer/npm." ;;
    npm) have npm || die "npm missing; install Node 22 first (sudo apt-get install -y nodejs npm, or nvm)"; npm install -g openclaw@latest ;;
    *) log INFO "installing OpenClaw via official installer"
       # sanitized env: our OPS_*/OPENCLAW_* site variables must not leak into the installer (it reads its own OPENCLAW_* envs)
       curl -fsSL https://openclaw.ai/install.sh -o /tmp/openclaw-install.sh
       env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" SHELL=/bin/bash PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin" TERM=dumb bash /tmp/openclaw-install.sh
       rm -f /tmp/openclaw-install.sh ;;
  esac
  hash -r; have openclaw || { export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"; hash -r; }
  have openclaw || die "openclaw still not on PATH after install; open a new login shell and re-run"
  log INFO "openclaw installed: $(openclaw --version 2>/dev/null | head -1)"
else log INFO "openclaw present: $(openclaw --version 2>/dev/null | head -1)"; fi

# Fresh install: the gateway refuses to start with no config (exit 78: "Missing config ... set gateway.mode=local").
# Seed a minimal local-mode config; 20-harden-config.sh then adds auth/bind/origins on top.
mkdir -p "$OPENCLAW_HOME"; chmod 700 "$OPENCLAW_HOME"
if [ ! -s "$OPENCLAW_HOME/openclaw.json" ]; then
  printf '{\n  "gateway": { "mode": "local" }\n}\n' > "$OPENCLAW_HOME/openclaw.json"
  log INFO "seeded minimal openclaw.json (gateway.mode=local)"
fi

unit="$HOME/.config/systemd/user/$OPENCLAW_SERVICE"
if [ ! -f "$unit" ]; then log INFO "openclaw gateway install"; openclaw gateway install || die "openclaw gateway install failed"; fi
[ -f "$unit" ] || die "unit $unit not created"
# Restart policy hardening (drop-in, never edit the generated unit)
dropin="$HOME/.config/systemd/user/${OPENCLAW_SERVICE}.d"; mkdir -p "$dropin"
cat > "$dropin/10-openclaw-ops.conf" <<'CONF'
[Service]
Restart=always
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=10
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=10
CONF
user_systemctl daemon-reload
user_systemctl enable --now "$OPENCLAW_SERVICE" >/dev/null 2>&1 || user_systemctl restart "$OPENCLAW_SERVICE"

# local health timer
for f in openclaw-ops-health.service openclaw-ops-health.timer; do sed "s#__REPO__#$OPS_REPO#g; s#__OPS_HOME__#$OPS_HOME#g" "$OPS_REPO/wsl/systemd/$f" > "$HOME/.config/systemd/user/$f"; done
user_systemctl daemon-reload; user_systemctl enable --now openclaw-ops-health.timer >/dev/null

for i in 1 2 3 4 5 6; do rpc_ok && break; sleep 5; done
rpc_ok || { user_systemctl status "$OPENCLAW_SERVICE" --no-pager | tail -20; journalctl --user -u "$OPENCLAW_SERVICE" -n 40 --no-pager; die "gateway RPC not OK after start"; }
log INFO "gateway service active, RPC ok, linger on"
bash "$OPS_REPO/wsl/healthcheck.sh"
