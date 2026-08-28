#!/usr/bin/env bash
# Kill the gateway every 8s for 3 minutes -> systemd start-limit trips -> supervisor sees a restart loop.
source "$(dirname "$0")/../../wsl/lib.sh"
( for i in $(seq 1 22); do pid=$(user_systemctl show -p MainPID --value "$OPENCLAW_SERVICE"); [ "$pid" != "0" ] && kill -9 "$pid"; sleep 8; done ) & echo "crashloop injector pid $! (3 min)"
