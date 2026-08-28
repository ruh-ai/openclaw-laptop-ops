#!/usr/bin/env bash
# Restore config + unit from a snapshot (name under $OPS_HOME/snapshots, 'last-known-good', or absolute dir). Validates, restarts, verifies.
source "$(dirname "$0")/lib.sh"
s="${1:-last-known-good}"; d="$s"; [ -d "$d" ] || d="$OPS_HOME/snapshots/$s"; [ -d "$d" ] || die "snapshot not found: $s"
d=$(readlink -f "$d"); [ -f "$d/openclaw-home-config.tgz" ] || die "no config tgz in $d"
pre=$(bash "$OPS_REPO/wsl/snapshot.sh" | tail -1); log INFO "rollback to $d (current state saved as $pre)"
tar -C "$OPENCLAW_HOME" -xzf "$d/openclaw-home-config.tgz"   # .env is never in snapshots, so the token survives
[ -f "$d/$OPENCLAW_SERVICE" ] && cp -p "$d/$OPENCLAW_SERVICE" "$HOME/.config/systemd/user/$OPENCLAW_SERVICE"
user_systemctl daemon-reload
openclaw config validate >/dev/null 2>&1 || die "restored config does not validate"
user_systemctl restart "$OPENCLAW_SERVICE"; sleep 6
for i in 1 2 3 4 5 6; do rpc_ok && { log INFO "rollback OK"; echo "rolled back to $(basename "$d")"; exit 0; }; sleep 5; done
die "gateway not healthy after rollback"
