#!/usr/bin/env bash
# Phase 2b/3b — gateway config hardening. Args: [--origin=https://host.tailnet.ts.net] [--trusted-proxy=IP]
#  - token auth, token lives in $OPENCLAW_HOME/.env (600), never in openclaw.json
#  - bind loopback; allowTailscale=false (Windows-side Serve can't be whois-verified from inside WSL)
#  - controlUi.allowedOrigins += origin ; trustedProxies += ip (VERIFY-ON-SITE which IP the gateway sees)
#  - `openclaw config validate` before restart; restores the previous file if validation fails
source "$(dirname "$0")/lib.sh"
origin=""; proxy=""
for a in "$@"; do case "$a" in --origin=*) origin="${a#*=}";; --trusted-proxy=*) proxy="${a#*=}";; esac; done
cfg="$OPENCLAW_HOME/openclaw.json"; envf="$OPENCLAW_HOME/.env"
mkdir -p "$OPENCLAW_HOME"; chmod 700 "$OPENCLAW_HOME"
# token
touch "$envf"; chmod 600 "$envf"
if ! grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$envf"; then
  tok=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$tok" >> "$envf"; log INFO "gateway token generated -> $envf (600)"
fi
install -m 600 /dev/null "$OPS_HOME/gateway-token.txt"; grep '^OPENCLAW_GATEWAY_TOKEN=' "$envf" | cut -d= -f2- > "$OPS_HOME/gateway-token.txt"
echo "NOTE: the human reads the pairing token with:  cat $OPS_HOME/gateway-token.txt   (do not echo it into agent transcripts)"

[ -f "$cfg" ] || echo '{}' > "$cfg"
bak="$OPS_HOME/snapshots/openclaw.json.pre-harden.$(date +%Y%m%d-%H%M%S)"; cp -p "$cfg" "$bak"
# Prefer the CLI if it supports `config set`; otherwise edit strict JSON with python; JSON5 with comments -> tell the human.
if openclaw config --help 2>/dev/null | grep -qE '^\s*set\b'; then
  cs() { openclaw config set "$1" "$2" >/dev/null || die "openclaw config set $1 failed"; }
  cs gateway.auth.mode token; cs gateway.bind loopback; cs gateway.auth.allowTailscale false; cs gateway.port "$GATEWAY_PORT"
  openclaw config unset gateway.auth.token >/dev/null 2>&1 || true
  [ -n "$origin" ] && cs gateway.controlUi.allowedOrigins "[\"$origin\"]"
  [ -n "$proxy" ] && cs gateway.trustedProxies "[\"$proxy\"]"
else
  python3 - "$cfg" "$origin" "$proxy" "$GATEWAY_PORT" <<'PY' || die "openclaw.json is not strict JSON (JSON5 with comments?). Edit by hand per RUNBOOK Phase 3 and re-run, or upgrade OpenClaw for 'config set'."
import json,sys
p,origin,proxy,port=sys.argv[1:5]
c=json.load(open(p)); g=c.setdefault('gateway',{}); a=g.setdefault('auth',{})
a['mode']='token'; a.pop('token',None); a['allowTailscale']=False; g['bind']='loopback'; g['port']=int(port)
if origin:
    ui=g.setdefault('controlUi',{}); ao=ui.setdefault('allowedOrigins',[]); origin not in ao and ao.append(origin)
if proxy:
    tp=g.setdefault('trustedProxies',[]); proxy not in tp and tp.append(proxy)
json.dump(c,open(p,'w'),indent=2); print('openclaw.json updated')
PY
fi
if ! openclaw config validate >/dev/null 2>&1; then cp -p "$bak" "$cfg"; openclaw config validate 2>&1 | tail -5; die "config failed validation — previous file restored from $bak"; fi
user_systemctl restart "$OPENCLAW_SERVICE"; sleep 6
if ! wait_rpc 24; then
  log WARN "RPC not OK after first restart; one more restart then extended wait"
  user_systemctl restart "$OPENCLAW_SERVICE"; sleep 8
  wait_rpc 16 || true
fi
rpc_ok || { journalctl --user -u "$OPENCLAW_SERVICE" -n 40 --no-pager; cp -p "$bak" "$cfg"; user_systemctl restart "$OPENCLAW_SERVICE"; die "gateway unhealthy after hardening - config restored from $bak"; }
log INFO "hardened: token auth, loopback, allowTailscale=false${origin:+, origin $origin}${proxy:+, trustedProxy $proxy}"
echo "VERIFY-ON-SITE: if UI pairing from the tailnet fails with a proxy/origin rejection, run: journalctl --user -u $OPENCLAW_SERVICE -n 100 | grep -iE 'proxy|origin|forward' and re-run with --trusted-proxy=<observed peer ip>"
