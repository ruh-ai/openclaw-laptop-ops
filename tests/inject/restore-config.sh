#!/usr/bin/env bash
# Undo break-config.sh (and --with-deps: undo break-dependency.sh).
source "$(dirname "$0")/../../wsl/lib.sh"
[ -f "$OPENCLAW_HOME/openclaw.json.test-bak" ] && mv -f "$OPENCLAW_HOME/openclaw.json.test-bak" "$OPENCLAW_HOME/openclaw.json" && echo "config restored"
if [ "${1:-}" = "--with-deps" ]; then bin=$(command -v openclaw || true); [ -n "$bin" ] && [ -f "$bin.test-moved" ] && mv -f "$bin.test-moved" "$bin" && echo "openclaw binary restored"; [ -f "$HOME/.openclaw-ops/TEST-FORCE-VERIFY-FAIL" ] && rm -f "$HOME/.openclaw-ops/TEST-FORCE-VERIFY-FAIL" && echo "verify marker removed"; fi
user_systemctl daemon-reload; user_systemctl restart "$OPENCLAW_SERVICE"; sleep 6; bash "$OPS_REPO/wsl/healthcheck.sh"
