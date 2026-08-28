#!/usr/bin/env bash
# Repair verification. Default: service active + RPC ok + local HTTP responds, for --cycles N (default 3) checks 20s apart.
#   --ai-auth : only check that the AI CLIs are authenticated (exit 0 = at least the primary works)
# Test hook: a file $OPS_HOME/TEST-FORCE-VERIFY-FAIL forces failure (used by tests/ACCEPTANCE.md).
source "$(dirname "$0")/../lib.sh"
if [ "${1:-}" = "--ai-auth" ]; then
  ok=0; [ -f "$HOME/.openclaw-ops/ai.env" ] && set -a && . "$HOME/.openclaw-ops/ai.env" && set +a
  for tool in "${AI_PRIMARY:-codex}" "${AI_SECONDARY:-none}"; do
    case "$tool" in
      codex) if have codex && { [ -n "${OPENAI_API_KEY:-}" ] || codex login status >/dev/null 2>&1; }; then echo "codex: authenticated"; ok=1; else echo "codex: NOT authenticated (run: codex login)"; fi ;;
      claude) if have claude && { [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -s "$HOME/.claude/.credentials.json" ]; }; then echo "claude: authenticated"; ok=1; else echo "claude: NOT authenticated (run: claude, then /login)"; fi ;;
    esac
  done; [ $ok -eq 1 ]; exit $?
fi
cycles=3; [ "${1:-}" = "--cycles" ] && cycles="${2:-3}"
[ -f "$OPS_HOME/TEST-FORCE-VERIFY-FAIL" ] && { echo "verify: forced failure (test marker present)"; exit 1; }
for i in $(seq 1 "$cycles"); do
  [ "$(service_state)" = "active" ] || { echo "verify: service not active (cycle $i)"; exit 1; }
  rpc_ok || { echo "verify: RPC failed (cycle $i)"; exit 1; }
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$GATEWAY_PORT/" || echo 000); [[ "$code" =~ ^(2|3|401|403) ]] || { echo "verify: HTTP $code (cycle $i)"; exit 1; }
  [ "$i" -lt "$cycles" ] && sleep 20
done
echo "verify: OK ($cycles cycles)"
