#!/usr/bin/env bash
# Snapshots. Secrets (.env, *credential*, *token*, *.key) are ALWAYS excluded. Prints the snapshot path/name as the LAST line.
#   snapshot.sh                      -> config snapshot into $OPS_HOME/snapshots/<ts>/
#   snapshot.sh --mark-good          -> snapshot + update $OPS_HOME/snapshots/last-known-good (symlink)   [prints name]
#   snapshot.sh --pre-repair         -> snapshot tagged pre-repair                                        [prints name]
#   snapshot.sh --full <dir>         -> nightly tar.gz of config+memory+skills+state+units+ops into <dir>  [prints file]
#   snapshot.sh --evidence <dir>     -> diagnostics bundle (status, journal, doctor, versions, hashes) into <dir>
source "$(dirname "$0")/lib.sh"
mode="${1:-}"; arg="${2:-}"; ts=$(date +%Y%m%d-%H%M%S)
EXCL=(--exclude='.env' --exclude='*credential*' --exclude='*token*' --exclude='*.key' --exclude='*.pem' --exclude='node_modules' --exclude='*.log' --exclude='cache' --exclude='.cache')
manifest() { { echo "ts=$(date -Is)"; echo "openclaw=$(openclaw --version 2>/dev/null | head -1)"; echo "node=$(node --version 2>/dev/null)"; echo "distro=$(. /etc/os-release; echo "$PRETTY_NAME")"; echo "kernel=$(uname -r)"; echo "config_sha=$(sha256sum "$OPENCLAW_HOME/openclaw.json" 2>/dev/null | cut -c1-16)"; echo "unit_sha=$(sha256sum "$HOME/.config/systemd/user/$OPENCLAW_SERVICE" 2>/dev/null | cut -c1-16)"; npm ls -g --depth=0 2>/dev/null | grep -i openclaw; } > "$1/MANIFEST.txt"; }
case "$mode" in
  --evidence)
    d="${arg:-$OPS_HOME/repair/evidence-$ts}"; mkdir -p "$d"
    { echo "== healthcheck"; bash "$OPS_REPO/wsl/healthcheck.sh"; echo "== systemctl"; user_systemctl status "$OPENCLAW_SERVICE" --no-pager -l 2>&1 | head -40
      echo "== journal (last 200)"; journalctl --user -u "$OPENCLAW_SERVICE" -n 200 --no-pager 2>&1; echo "== gateway status"; timeout 40 openclaw gateway status 2>&1 | head -40
      echo "== doctor"; timeout 120 openclaw doctor 2>&1 | head -60; echo "== config validate"; openclaw config validate 2>&1 | head -20
      echo "== listeners"; ss -ltnp 2>/dev/null; echo "== df/mem"; df -h /; free -m; echo "== processes"; ps aux --sort=-%mem | head -15
      echo "== recent apt"; tail -n 30 /var/log/apt/history.log 2>/dev/null; echo "== recent repairs"; tail -n 5 "$OPS_HOME/repairs.jsonl" 2>/dev/null; } > "$d/diagnostics.txt" 2>&1
    mkdir -p "$d/config"; tar -C "$OPENCLAW_HOME" "${EXCL[@]}" -czf "$d/config/openclaw-home-config.tgz" --exclude='memory' --exclude='workspace*' --exclude='sessions' . 2>/dev/null || true
    cp -p "$HOME/.config/systemd/user/$OPENCLAW_SERVICE" "$d/config/" 2>/dev/null || true; manifest "$d"; echo "$d" ;;
  --full)
    dest="${arg:-$OPS_HOME/backups}"; mkdir -p "$dest"; f="$dest/openclaw-backup-$ts.tar.gz"; tmp=$(mktemp -d)
    mkdir -p "$tmp/openclaw-home" "$tmp/systemd" "$tmp/ops"; manifest "$tmp"
    tar -C "$OPENCLAW_HOME" "${EXCL[@]}" -cf - . 2>/dev/null | tar -C "$tmp/openclaw-home" -xf - || true
    cp -rp "$HOME/.config/systemd/user/$OPENCLAW_SERVICE"* "$tmp/systemd/" 2>/dev/null || true
    cp -p "$OPS_HOME"/repairs.jsonl "$OPS_HOME"/logs/ops.log "$tmp/ops/" 2>/dev/null || true
    tar -C "$tmp" -czf "$f" . && rm -rf "$tmp"; [ -s "$f" ] || die "backup tar empty"; log INFO "full backup $f ($(du -h "$f" | cut -f1))"; echo "$f" ;;
  *)
    tag="snap"; [ "$mode" = "--pre-repair" ] && tag="pre-repair"; d="$OPS_HOME/snapshots/$ts-$tag"; mkdir -p "$d"
    tar -C "$OPENCLAW_HOME" "${EXCL[@]}" -czf "$d/openclaw-home-config.tgz" --exclude='memory' --exclude='workspace*' --exclude='sessions' --exclude='media' . 2>/dev/null || true
    cp -rp "$HOME/.config/systemd/user/$OPENCLAW_SERVICE"* "$d/" 2>/dev/null || true; manifest "$d"
    if [ "$mode" = "--mark-good" ]; then ln -sfn "$d" "$OPS_HOME/snapshots/last-known-good"; log INFO "last-known-good -> $d"; fi
    ls -1dt "$OPS_HOME"/snapshots/*-snap "$OPS_HOME"/snapshots/*-pre-repair 2>/dev/null | tail -n +21 | xargs -r rm -rf   # keep 20
    echo "$(basename "$d")" ;;
esac
