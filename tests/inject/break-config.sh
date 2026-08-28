#!/usr/bin/env bash
# Inject an invalid key into openclaw.json (gateway refuses to start on schema violation). Saves a .test-bak first.
source "$(dirname "$0")/../../wsl/lib.sh"
cp -p "$OPENCLAW_HOME/openclaw.json" "$OPENCLAW_HOME/openclaw.json.test-bak"
python3 - "$OPENCLAW_HOME/openclaw.json" <<'PY'
import json,sys; p=sys.argv[1]; c=json.load(open(p)); c['gateway']['thisKeyDoesNotExist_test']=True; c['gateway']['port']='not-a-number'; json.dump(c,open(p,'w'),indent=2)
PY
user_systemctl restart "$OPENCLAW_SERVICE" || true; echo "config broken; .test-bak saved. Restore: tests/inject/restore-config.sh"
