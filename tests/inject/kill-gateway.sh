#!/usr/bin/env bash
# Kill the gateway once (systemd should restart it). --stop-loop: stop it and hold it stopped for 4 minutes so the supervisor must act.
source "$(dirname "$0")/../../wsl/lib.sh"
if [ "${1:-}" = "--stop-loop" ]; then user_systemctl stop "$OPENCLAW_SERVICE"; echo "stopped; holding down for 240s"; ( for i in $(seq 1 24); do sleep 10; user_systemctl stop "$OPENCLAW_SERVICE" 2>/dev/null; done ) & echo "background holder pid $!"; exit 0; fi
pid=$(user_systemctl show -p MainPID --value "$OPENCLAW_SERVICE"); [ "$pid" != "0" ] && kill -9 "$pid" && echo "killed main pid $pid" || echo "no main pid"
