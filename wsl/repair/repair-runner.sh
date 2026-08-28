#!/usr/bin/env bash
# AI repair runner. Invoked by windows/supervisor/Invoke-Recovery.ps1 (RECOVERY_MODE=repair) as WSL_USER.
#   repair-runner.sh --evidence <dir>     (dir already contains health.json from Windows; we add WSL diagnostics)
# Steps: lock -> AI auth -> pre-repair snapshot -> workdir with AGENTS.md/CLAUDE.md = REPAIR_PROMPT -> run primary (then secondary)
#        -> verify.sh -> on failure rollback to pre-repair snapshot -> append to $OPS_HOME/repairs.jsonl. Exit 0 only on verified success.
source "$(dirname "$0")/../lib.sh"
ev=""; for a in "$@"; do case "$a" in --evidence) shift; ev="$1";; esac; done
lock="$OPS_HOME/repair/.lock"
exec 9>"$lock"; flock -n 9 || die "another repair is running"
[ -f "$HOME/.openclaw-ops/ai.env" ] && set -a && . "$HOME/.openclaw-ops/ai.env" && set +a
ts=$(date +%Y%m%d-%H%M%S); work="$OPS_HOME/repair/$ts"; mkdir -p "$work/evidence"
[ -n "$ev" ] && [ -d "$ev" ] && cp -rp "$ev"/. "$work/evidence/" 2>/dev/null
bash "$OPS_REPO/wsl/snapshot.sh" --evidence "$work/evidence" >/dev/null 2>&1 || true
pre=$(bash "$OPS_REPO/wsl/snapshot.sh" --pre-repair | tail -1); log INFO "pre-repair snapshot $pre"
lkg=$(readlink -f "$OPS_HOME/snapshots/last-known-good" 2>/dev/null || echo "none")
tail -n 5 "$OPS_HOME/repairs.jsonl" 2>/dev/null > "$work/previous-attempts.txt" || echo "none" > "$work/previous-attempts.txt"
sed -e "s#__SERVICE__#$OPENCLAW_SERVICE#g; s#__USER__#$(id -un)#g; s#__OPENCLAW_HOME__#$OPENCLAW_HOME#g; s#__PORT__#$GATEWAY_PORT#g; s#__LKG__#$lkg#g; s#__REPO__#$OPS_REPO#g" \
  "$OPS_REPO/wsl/repair/REPAIR_PROMPT.md" > "$work/AGENTS.md"; cp "$work/AGENTS.md" "$work/CLAUDE.md"
task="OpenClaw gateway is unhealthy. Read AGENTS.md and ./evidence/diagnostics.txt, find the root cause, repair, run verify.sh, write RESULT.md."
timeout_s=$(( ${AI_REPAIR_TIMEOUT_MIN:-20} * 60 ))
run_tool() {
  local tool="$1" out="$work/$1.log"
  case "$tool" in
    codex) have codex || return 127
      ( cd "$work" && timeout "$timeout_s" codex exec --dangerously-bypass-approvals-and-sandbox -C "$work" ${CODEX_MODEL:+-m "$CODEX_MODEL"} -o "$work/codex-last.txt" "$task" ) >"$out" 2>&1 ;;
    claude) have claude || return 127
      ( cd "$work" && timeout "$timeout_s" claude -p "$task" --permission-mode bypassPermissions --max-turns 60 ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} --output-format text ) >"$out" 2>&1 ;;
    *) return 127 ;;
  esac
}
result="failed"; used=""
for tool in "${AI_PRIMARY:-codex}" "${AI_SECONDARY:-none}"; do
  [ "$tool" = "none" ] && continue
  log INFO "AI repair via $tool (timeout ${timeout_s}s)"; run_tool "$tool"; rc=$?; used="$tool"
  if [ $rc -eq 127 ]; then log WARN "$tool not available"; continue; fi
  if bash "$OPS_REPO/wsl/repair/verify.sh" >"$work/verify.log" 2>&1; then result="success"; break; fi
  log WARN "$tool did not achieve verification (rc=$rc); rolling back to $pre before next attempt"
  bash "$OPS_REPO/wsl/rollback.sh" "$pre" >/dev/null 2>&1 || true
done
summary=$(grep -v -iE 'token|key|secret|password' "$work/RESULT.md" 2>/dev/null | head -c 1200 | tr '\n' ' ' | sed 's/"/\\"/g')
printf '{"ts":"%s","result":"%s","tool":"%s","pre_snapshot":"%s","work":"%s","summary":"%s"}\n' "$(date -Is)" "$result" "$used" "$pre" "$work" "$summary" >> "$OPS_HOME/repairs.jsonl"
echo "AI repair $result via ${used:-none}. Work dir: $work"; [ -n "$summary" ] && echo "$summary"
[ "$result" = "success" ]
