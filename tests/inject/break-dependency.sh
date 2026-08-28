#!/usr/bin/env bash
# Simulate a broken dependency: move the openclaw entrypoint aside so the unit fails to exec (AI-repairable: reinstall/relink).
# --unfixable: additionally plant the TEST-FORCE-VERIFY-FAIL marker so any repair fails verification -> tests rollback + cooldown.
source "$(dirname "$0")/../../wsl/lib.sh"
bin=$(command -v openclaw) || die "openclaw not found"; [ -f "$bin.test-moved" ] && die "already broken"
mv "$bin" "$bin.test-moved"; user_systemctl restart "$OPENCLAW_SERVICE" || true; echo "moved $bin aside"
[ "${1:-}" = "--unfixable" ] && touch "$HOME/.openclaw-ops/TEST-FORCE-VERIFY-FAIL" && echo "verify will be forced to fail"
echo "Restore: tests/inject/restore-config.sh --with-deps"
