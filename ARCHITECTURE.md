# OpenClaw on a single Windows laptop — resilience architecture

**Decision (2026-08-27):** everything runs on the client's Windows laptop. No external VPS. This is
"option 2 — layered supervisor with AI repair": Tailscale + SSH at the Windows level, WSL 2 with
systemd keeping the OpenClaw Gateway alive, a Windows supervisor that can restart WSL from outside it,
a staged recovery ladder that ends in a Codex/Claude Code repair runner, and Slack for state-change
reporting. The Windows-level remote-access path is protected from the repair runner so an autonomous
repair can never lock us out.

This document is the consolidated design. `RUNBOOK.md` is the procedure. `config/site.env` holds the
machine facts every script reads (see `config/site.env.example` for every variable used below).

---

## 0. Accepted limitations (read first)

A laptop-only design cannot repair or even alert on:

- power loss when firmware cannot power the laptop back on;
- router / ISP failure;
- a frozen Windows, a blue screen, or hardware failure;
- complete disk failure (all backups live on the same disk);
- Tailscale account revocation or an access-policy mistake that removes both operators;
- simultaneous outage of both configured AI providers (deterministic recovery still runs).

In those cases the laptop can only report the availability gap **after** it comes back
(`HEARTBEAT_GAP_ALERT_MIN` in `site.env`), and TeamViewer or a person physically at the laptop is
the final recovery path. **TeamViewer stays installed and running.**

---

## 1. Access and recovery boundaries

```
You + second operator
          │
          │ Tailscale private network (tailnet ACL: only the two operator identities)
          ▼
┌──────────────────────────── Windows laptop ─────────────────────────────┐
│                                                                         │
│  Tailscale  (Windows service, unattended mode, tagged device)           │
│    ├─ Windows OpenSSH  ← firewall scoped to 100.64.0.0/10 only          │
│    └─ Tailscale Serve  https://<TS_HOSTNAME>.<TS_TAILNET>/              │
│                              └─► http://127.0.0.1:<GATEWAY_PORT>       │
│                                                                         │
│  Windows supervisor  (scheduled task OpenClawOps-Supervisor, 1 min)     │
│    ├─ starts WSL after every boot (OpenClawOps-WslBoot)                 │
│    ├─ checks Tailscale, WSL, systemd, gateway RPC, UI, Serve, disk      │
│    ├─ restarts a failed WSL instance (from outside WSL)                 │
│    ├─ escalates to the AI repair runner when simple recovery fails      │
│    └─ sends Slack state changes (DPAPI-protected webhook)               │
│                       │  wsl.exe -d <DISTRO> -u <WSL_USER> -- bash …    │
│                       ▼                                                 │
│  ┌──────────────────── WSL 2  (<DISTRO>) ─────────────────────────────┐ │
│  │ systemd  (/etc/wsl.conf [boot] systemd=true)                        │ │
│  │   ├─ openclaw-gateway.service   (systemd --user, <WSL_USER>, linger)│ │
│  │   ├─ openclaw-ops-health.timer  (local health checker)              │ │
│  │   ├─ repair runner  (codex exec / claude -p, as <WSL_USER>)         │ │
│  │   └─ ~/.openclaw-ops/  logs, snapshots, repair history              │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Windows layer

| Component | Decision | Repo file |
|---|---|---|
| Tailscale | Installed **on Windows only**, `tailscale up --unattended` so it connects before anyone signs in; logged in with a **tagged, pre-approved auth key** (`TS_TAGS`) so device key expiry is disabled by default. Never a second Tailscale inside WSL — Tailscale warns that running both causes nested packet-size (MTU) problems. | `windows/10-tailscale.ps1` |
| OpenSSH Server | Windows OpenSSH (`sshd`), key-only auth, `AllowGroups <SSH_GROUP>` (lowercase), firewall rule `OpenClawOps-SSH-Tailnet` scoped to `SSH_TAILNET_CIDR` (100.64.0.0/10). Default shell PowerShell. Operators' public keys from `config/operators/*.pub`. | `windows/11-openssh.ps1` |
| Private UI publish | `tailscale serve --bg --https=<TS_SERVE_HTTPS_PORT> http://127.0.0.1:<GATEWAY_PORT>` — persists across reboots and Tailscale restarts. Reachable only by tailnet members the ACL allows. | `windows/12-tailscale-serve.ps1` |
| WSL boot | Scheduled task `OpenClawOps-WslBoot`, trigger *at startup*, runs as `WIN_USER` (the distro owner — WSL distros are user-scoped; SYSTEM would not find it), action `wsl.exe -d <DISTRO> --exec dbus-launch true` (per OpenClaw's WSL doc; `dbus-launch true`, not `/bin/true`, avoids WSL ≥ 2.6.1 idle termination). | `windows/30-startup-task.ps1` |
| Supervisor | Scheduled task `OpenClawOps-Supervisor`, every `SUPERVISOR_INTERVAL_MIN`, runs as `WIN_USER`, execution lock prevents overlap. Lives outside WSL so it can restart WSL. | `windows/supervisor/Supervisor.ps1` |
| Power | No sleep/hibernate on AC, lid close does nothing on AC, NIC power-saving off, Windows Update restarts allowed inside a maintenance window, firmware "power on after AC loss" if available. **Automatic Windows login stays disabled** — unnecessary and weakens security. | `windows/40-power.ps1` |
| Fallback | TeamViewer remains installed. Emergency path only. | (never touched by scripts) |

Administration model: SSH into **Windows** over Tailscale, then `wsl -d <DISTRO>`. This is more
resilient than an SSH server inside WSL, because Windows-level SSH still works when WSL is broken.

### 1.2 OpenClaw access path (and why token auth stays)

```
operator browser ──TLS──► Windows Tailscale Serve ──► 127.0.0.1:<GATEWAY_PORT> (Windows)
                                                          │ WSL localhostForwarding
                                                          ▼
                                            gateway inside WSL, bind=loopback
```

- The gateway keeps `gateway.bind: "loopback"` and listens on `GATEWAY_PORT` (default 18789).
- Windows reaches WSL loopback services via WSL's `localhostForwarding` (NAT mode default).
- **Auth stays `gateway.auth.mode: "token"`.** OpenClaw's tokenless Tailscale identity flow
  (`gateway.auth.allowTailscale`) verifies the `x-forwarded-for` address through the *local*
  `tailscale whois`. There is no tailscaled inside WSL, so that check can never succeed here. The
  token lives in `${OPENCLAW_HOME}/.env` as `OPENCLAW_GATEWAY_TOKEN`, readable only by `WSL_USER`.
- Because Serve is an **externally managed proxy** from the gateway's point of view, two config keys
  are mandatory:
  - `gateway.trustedProxies` — the immediate source address of proxied connections as the gateway
    sees them. Without it, proxied connections are rejected on authenticated routes.
  - `gateway.controlUi.allowedOrigins` — `https://<TS_HOSTNAME>.<TS_TAILNET>` — required whenever
    the Control UI is served via a proxy under a different hostname.
- Applied by `wsl/20-harden-config.sh`, validated with `openclaw config validate`, then
  `openclaw doctor`.

> **VERIFY ON-SITE (a):** what source IP the gateway inside WSL actually observes for connections
> arriving through Windows Serve → localhostForwarding. It may be `127.0.0.1` or the WSL NAT host
> address (which can change across reboots). `RUNBOOK.md` Phase 3 has the step: connect through the
> ts.net URL, read the observed peer address from gateway logs, and set `trustedProxies` from what is
> observed — not from this document. If the address is non-stable, the runbook's fallback is
> `.wslconfig` `networkingMode=mirrored` (where `127.0.0.1` is shared), re-verified.

### 1.3 WSL layer

| Component | Decision | Repo file |
|---|---|---|
| systemd | `/etc/wsl.conf` `[boot] systemd=true`; `wsl --shutdown` to apply. `.wslconfig` sets `vmIdleTimeout=<WSL_VM_IDLE_TIMEOUT_MS>` and optional `memory=<WSL_MEMORY>`. | `windows/20-wsl-prepare.ps1` |
| Gateway service | `openclaw gateway install` → `systemd --user` unit `openclaw-gateway.service` for `WSL_USER`; `sudo loginctl enable-linger <WSL_USER>` so the user manager survives logout; `Restart=` policy, `MemoryMax`, persistent journald. | `wsl/10-openclaw-service.sh` |
| Config hardening | token → `.env`, `bind=loopback`, `trustedProxies`, `allowedOrigins`, `config validate`, `doctor`. Secrets removed from `openclaw.json`. | `wsl/20-harden-config.sh` |
| Local health | `openclaw-ops-health.timer` runs `wsl/healthcheck.sh` inside WSL (systemd active + `gateway status --require-rpc` + HTTP probe) and writes `~/.openclaw-ops/health.json` for the Windows supervisor to read. | `wsl/systemd/openclaw-ops-health.{service,timer}`, `wsl/healthcheck.sh` |
| Accounts | Gateway, repair runner, snapshots and state all under `WSL_USER` — **not root**. | all `wsl/*.sh` |
| Invocation from Windows | `windows/Invoke-WslScript.ps1 -Script wsl/<x>.sh` ≡ `wsl.exe -d <DISTRO> -u <WSL_USER> -- bash /mnt/c/openclaw-laptop-ops/wsl/<x>.sh`. | `windows/Invoke-WslScript.ps1` |

> **VERIFY ON-SITE (b):** whether the installed WSL version accepts `vmIdleTimeout=-1` (disable) or
> only a positive millisecond value. `site.env` defaults to `3600000` (1 h); the discovery report
> records `wsl --version` and the runbook says which to use.

### 1.4 Protected recovery path

The AI repair runner may change: OpenClaw code and dependencies, `openclaw.json`, `.env` keys it
is told about, the `openclaw-gateway.service` unit, WSL-internal services, package versions (forward
or back). It runs as `WSL_USER` inside WSL and therefore **cannot** reach, and the on-site agent
**must not** touch after Phase 1:

- Windows Tailscale configuration and `tailscale up` arguments, Serve configuration
- Tailscale access policy (tailnet ACL)
- Windows OpenSSH (`sshd`, `%ProgramData%\ssh\*`, `administrators_authorized_keys`)
- Windows Firewall rules `OpenClawOps-*`
- The scheduled tasks `OpenClawOps-*` (its own startup and supervisor tasks)
- The immutable copy of the recovery scripts (`REPO_DIR_WIN`, Windows-ACL'd; WSL sees it read-only
  in practice via `/mnt/c` and the runner is told never to edit it)
- TeamViewer

Enforced by: Linux user boundary (runner is not root, has no Windows credentials), the
`wsl/repair/REPAIR_PROMPT.md` forbidden list, and `wsl/repair/verify.sh` refusing to accept a repair
that changed anything outside the allowed paths.

---

## 2. Health checks and autonomous repair

Codex/Claude Code is invoked **only** when deterministic recovery cannot fix the problem.

```
Healthy
  │
  ├─ check fails once ──────────► confirm (CONFIRM_FAILURES consecutive cycles)
  │
  └─ confirmed failure
           │
           ▼
     restart OpenClaw gateway          (systemctl --user restart; wait for RPC)
           │ still failing
           ▼
     restart WSL distro                (wsl --terminate <DISTRO>; start; wait for systemd; verify)
           │ still failing
           ▼
     restore last-known-good config    (wsl/rollback.sh; verify)
           │ still failing
           ▼
     AI repair                         (wsl/repair/repair-runner.sh)
           │
      verify repeatedly (STABILIZATION_CYCLES)
       ┌───┴────┐
       ▼        ▼
   recovered   failed ──► cooldown (AI_COOLDOWN_MIN) + keep safe restarts + retry later
```

### 2.1 Health checks (Windows supervisor, `windows/supervisor/HealthCheck.ps1`)

| Cadence | Check | How |
|---|---|---|
| every minute | Tailscale service running, node online | `Get-Service Tailscale`; `tailscale status --json` |
| every minute | WSL distro running | `wsl -l --running` contains `DISTRO` |
| every minute | systemd up inside WSL | `systemctl is-system-running` (accept `running`/`degraded`) |
| every minute | gateway unit active | `systemctl --user is-active openclaw-gateway.service` as `WSL_USER` |
| every minute | **real RPC response, not just an open port** | `openclaw gateway status --require-rpc` (via `wsl/healthcheck.sh` → `~/.openclaw-ops/health.json`) |
| every 5 min | UI endpoint via Windows localhost | `Invoke-WebRequest http://127.0.0.1:<GATEWAY_PORT>/` |
| every 5 min | Serve route | `tailscale serve status`; `Invoke-WebRequest https://<TS_HOSTNAME>.<TS_TAILNET>/` |
| every 15 min | configured channels / essential integrations | `openclaw health` |
| periodic | disk (C: and WSL root) vs `DISK_WARN_PCT`, memory pressure, Windows pending-restart, internet, **AI repair-agent auth** (`codex login status` / `claude auth status`), Tailscale key expiry | supervisor |
| after boot | availability gap: compare last heartbeat in `state.json` with boot time; alert if > `HEARTBEAT_GAP_ALERT_MIN` | supervisor |

A single failed check never triggers recovery. `CONFIRM_FAILURES` (default 2) consecutive failed
cycles are required, so a brief network blip does not restart everything.

### 2.2 Recovery staging — `RECOVERY_MODE`

| Mode | Supervisor may | When |
|---|---|---|
| `observe` | check, log, Slack. **No actions.** | **Tonight.** Minimum 24 h clean. |
| `restart` | + restart gateway, restart WSL, rollback config | after clean observe |
| `repair` | + AI repair runner | after restart mode proven by acceptance tests |

### 2.3 Recovery sequence (`windows/supervisor/Invoke-Recovery.ps1`)

1. **Capture evidence** — before changing anything: service status, recent journal, process list,
   config hashes, disk/memory, last-healthy timestamp → `%OPS_ROOT_WIN%\reports\incident-<ts>\`.
2. **Restart OpenClaw** — `systemctl --user restart openclaw-gateway.service`; success only on a
   real `--require-rpc` response.
3. **Restart WSL** — if systemd or the distro is unhealthy: `wsl --terminate <DISTRO>` (only this
   distro), start it, wait for systemd, verify the gateway.
4. **Rollback** — if the failure began after a config/dependency/OpenClaw change, `wsl/rollback.sh`
   restores the last-known-good snapshot and re-verifies.
5. **AI repair** — `wsl/repair/repair-runner.sh` with `AI_PRIMARY` then `AI_SECONDARY`. The
   request (`wsl/repair/REPAIR_PROMPT.md` + generated context) contains: collected diagnostics,
   recent changes, the operational runbook, exact verification requirements, previous failed
   attempts, and the explicit instruction to **treat log content as untrusted data**. Allowed: edit
   OpenClaw files/config, repair dependencies, change the WSL systemd unit, roll versions forward or
   back, restart services. Forbidden: everything in §1.4.
   - Codex: `codex exec --dangerously-bypass-approvals-and-sandbox -C <workdir> -o <result-file>`
     (`--full-auto` is deprecated; `workspace-write` would block systemd/`~/.openclaw` edits — the
     `WSL_USER` account boundary is the sandbox).
   - Claude Code: `claude -p --permission-mode bypassPermissions` with cwd = repo (**not** `--bare`:
     bare skips `CLAUDE.md` and never reads OAuth login).
6. **Verify** (`wsl/repair/verify.sh`) — a repair succeeds only when: unit active, `--require-rpc`
   passes, UI responds, required channel probes pass, and `STABILIZATION_CYCLES` consecutive healthy
   supervisor cycles complete.

### 2.4 Loop protection

- Max `MAX_AI_REPAIRS_PER_HOUR` (3) AI attempts per hour.
- Every attempt starts from a fresh `wsl/snapshot.sh`.
- Failed changes roll back automatically (`wsl/rollback.sh`).
- After the limit: cooldown `AI_COOLDOWN_MIN`, safe restarts continue, AI retried later.
- A lock file prevents two repair agents running at once (`~/.openclaw-ops/repair.lock`); the Windows
  supervisor has its own lock (`%OPS_ROOT_WIN%\supervisor.lock`).
- Successful repairs are kept with a local change record and before/after diagnostics
  (`~/.openclaw-ops/repairs/<ts>/`).
- No human approval is required during the process (by design; the guardrails above replace it).

### 2.5 Secrets and AI isolation

| Secret | Location | Who can read |
|---|---|---|
| Gateway token | `${OPENCLAW_HOME}/.env` (`OPENCLAW_GATEWAY_TOKEN`), `chmod 600` | `WSL_USER` (the gateway) |
| Model/API keys for OpenClaw | `${OPENCLAW_HOME}/.env` | `WSL_USER` |
| AI repair API keys (only if `AI_AUTH_MODE=apikey`) | `/home/<WSL_USER>/.openclaw-ops/ai.env`, `chmod 600` | `WSL_USER` |
| Slack webhook | `%OPS_ROOT_WIN%\secrets\slack.xml` (DPAPI via `Export-Clixml`) | `WIN_USER` only — DPAPI is per-user, so the supervisor task **must** run as the same account that ran `windows/secrets/Set-OpsSecret.ps1` |
| Tailscale auth key | typed live into `windows/10-tailscale.ps1`; never stored | — |
| GitHub PAT (clone) | typed live; remote URL rewritten to strip it | — |

The repair runner is told which `.env` keys exist by *name* and can restart the gateway, but the
prompt and the runbook forbid reading or printing secret files; logs can contain untrusted content,
so the runner never needs credentials it does not use.

> **Current deviation (v1):** the repair runner (`wsl/repair/repair-runner.sh`) runs as `WSL_USER` — the same
> Linux account as the gateway — so it *could* read `${OPENCLAW_HOME}/.env`; the prohibition is enforced by the
> prompt and by post-run redaction, not by file permissions. The intended end state is a dedicated
> `openclaw-repair` user with narrow sudo rights and no read access to `.env`. Tracked in `RUNBOOK.md` → Later.

### 2.6 Slack reporting

Sent by the **Windows supervisor**, not by OpenClaw — so it still reports when WSL or OpenClaw is
broken. State changes only, never routine noise:

- failure detected · recovery step started · AI repair invoked · recovery succeeded (with changes) ·
  recovery failed and cooldown started · Windows restarted and an availability gap was detected ·
  daily health summary · "system available" after a verified boot.

Delivery is queued locally (`%OPS_ROOT_WIN%\slack-queue.jsonl`) and retried when Slack or the
internet is unavailable.

---

## 3. Boot, identities, and backups

### 3.1 Boot sequence

```
Windows boots
   │
   ├─ Tailscale service starts (unattended)
   ├─ Windows OpenSSH Server starts
   ├─ Tailscale Serve restores the private UI route
   │
   └─ OpenClawOps-WslBoot (at startup, WIN_USER, network-delay)
          │
          ▼
       starts WSL  (wsl.exe -d <DISTRO> --exec dbus-launch true)
          │
          ▼
       systemd starts
          │
          ├─ openclaw-gateway.service
          ├─ openclaw-ops-health.timer
          └─ repair-controller support state
                 │
                 ▼
       OpenClawOps-Supervisor verifies the full chain → Slack "system available"
```

No Windows login and no open terminal is required. The startup task: triggers at startup with a short
network delay; starts the distro; confirms systemd; starts the gateway if not active; runs the full
health check; sends Slack "system available" **only after verification**. A second trigger runs the
supervisor every minute with an execution lock.

`[HUMAN AT CONSOLE]` The task must run "whether user is logged on or not" as `WIN_USER`; Windows
asks for that account's password when the task is registered — a human types it.

> Failure mode to remember: `wsl.exe --exec dbus-launch true` exits immediately; what keeps the VM
> alive is systemd + the gateway. If the VM idles out it looks like "OpenClaw crashed" but is
> "WSL terminated". Hence the "WSL distro running" check and `WSL_VM_IDLE_TIMEOUT_MS`.

### 3.2 Windows resilience settings (`windows/40-power.ps1`)

Tailscale unattended; OpenSSH + Tailscale services automatic with service-recovery restarts; no
sleep/hibernate on AC; lid does nothing on AC; NIC power saving off; Windows Update may restart within
a maintenance window (boot sequence restores everything); firmware power-on-after-AC-loss if
supported; automatic Windows login **stays disabled**.

### 3.3 Operator identities

- Separate Tailscale identities for you and the second operator.
- Separate Windows SSH accounts and keys (`config/operators/<name>.pub`); password SSH disabled after
  key auth is validated.
- Local Windows group `SSH_GROUP` (`openclaw-operators`) controls SSH.
- Tailnet ACL (`config/tailscale-acl.example.hujson`) permits only those two identities to reach
  `tag:openclaw-laptop` on `SSH_PORT` and `TS_SERVE_HTTPS_PORT`.
- Elevation available when required; routine checks run without it.
- Result: logs show *which* operator connected and when.

### 3.4 Backup layers

Backups must exist **before** the repair runner changes anything.

| Layer | What | Where | Retention | Repo file |
|---|---|---|---|---|
| Pre-repair snapshot | `openclaw.json`, systemd unit, package versions, changed app files, hashes, exact OpenClaw version, SQLite-safe copies of state DBs, pointer to last-known-good | `/home/<WSL_USER>/.openclaw-ops/snapshots/<ts>/` (+ mirrored to `%OPS_ROOT_WIN%\snapshots\`) | last 20 | `wsl/snapshot.sh`, `wsl/rollback.sh` |
| Nightly | config, memory, skills, schedules, workspace metadata, ops scripts, state — secrets excluded or encrypted | `%OPS_ROOT_WIN%\backups\daily\` (Windows-protected, outside the WSL filesystem) | `BACKUP_DAILY_KEEP`=7 daily, `BACKUP_WEEKLY_KEEP`=4 weekly | `windows/backup/Backup-OpenClaw.ps1` (task `OpenClawOps-BackupNightly`, `BACKUP_NIGHTLY_TIME`) |
| Weekly WSL export | `wsl --export <DISTRO>`; archive listed and non-empty before older exports are pruned; skipped with a Slack notice when free space < `MIN_FREE_GB_FOR_EXPORT` | `%OPS_ROOT_WIN%\backups\wsl-export\` | newest verified + previous | `windows/backup/Export-Wsl.ps1` (task `OpenClawOps-WslExport`, `WSL_EXPORT_DAY` `WSL_EXPORT_TIME`) |
| Change history | ops scripts + non-secret config in a local git repo; repair runner records before/after + verification; a repaired state becomes last-known-good only after the stabilization period | `/home/<WSL_USER>/.openclaw-ops/` (git), `repairs/<ts>/` | — | `wsl/repair/repair-runner.sh` |

All backups are on the same laptop: they protect against bad repairs, broken upgrades and WSL
corruption — not theft or disk failure (§0).

---

## 4. Rollout and failure testing

### 4.1 Rollout order (→ `RUNBOOK.md` phases)

| # | Step | Repo files | When |
|---|---|---|---|
| 0 | **Discovery & safety snapshot** — Windows/WSL/OpenClaw versions, distro name and owner, gateway config, ports, services, disk, installed AI tools; WSL export + OpenClaw backup before any change; fill `config/site.env`. | `windows/bootstrap.ps1`, `windows/00-discovery.ps1`, `windows/backup/Export-Wsl.ps1`, `windows/backup/Backup-OpenClaw.ps1` | tonight |
| 1 | **Remote access** while TeamViewer is connected — Tailscale (unattended, tagged key), both operators added, ACL, OpenSSH with separate keys, restricted to the two operators and the Tailscale interface; test both accounts. TeamViewer stays until access survives a full reboot. | `windows/10-tailscale.ps1`, `windows/11-openssh.ps1`, `config/tailscale-acl.example.hujson`, `config/operators/*.pub` | tonight |
| 2 | **WSL runtime** — WSL 2 + systemd, gateway as managed systemd service, secrets separated from config, persistent logging + local health, Windows→WSL localhost reachability confirmed. | `windows/20-wsl-prepare.ps1`, `windows/21-wsl-openclaw.ps1`, `wsl/10-openclaw-service.sh`, `wsl/20-harden-config.sh`, `wsl/systemd/*`, `wsl/healthcheck.sh` | tonight |
| 3 | **Publish privately** — persistent Serve, UI + Gateway only via tailnet HTTPS, OpenClaw auth required; verify UI, WebSocket, RPC and device pairing from both operators' machines; confirm unreachable outside the tailnet. | `windows/12-tailscale-serve.ps1`, `wsl/20-harden-config.sh` | tonight |
| 4 | **Supervision (observe) + backups** — protected startup and supervisor tasks, WSL health components, Slack webhook in DPAPI, snapshots/locks/cooldowns/audit configured, `RECOVERY_MODE=observe`; first backup + export verified; power settings; **live reboot test**. | `windows/30-startup-task.ps1`, `windows/40-power.ps1`, `windows/supervisor/*`, `windows/secrets/Set-OpsSecret.ps1`, `windows/backup/*`, `windows/90-verify.ps1` | tonight |
| 5 | **Enable restart recovery** — `RECOVERY_MODE=restart`, run the restart-tier acceptance tests. | `config/site.env`, `tests/ACCEPTANCE.md` | later (after 24 h clean observe) |
| 6 | **Enable AI repair** — configure Codex/Claude auth for `WSL_USER`, `RECOVERY_MODE=repair`, run the repair-tier acceptance tests. | `wsl/repair/*`, `config/site.env` | later |

### 4.2 Acceptance matrix (summary — full procedures in `tests/ACCEPTANCE.md`)

| Failure introduced | Expected recovery |
|---|---|
| Stop OpenClaw Gateway | systemd restores it within ~2 min |
| Kill the OpenClaw process repeatedly | supervisor detects restart loop and escalates |
| Terminate the WSL distribution | Windows starts WSL and OpenClaw again |
| Invalid OpenClaw configuration | rollback or AI repair restores service |
| Broken dependency | AI repair diagnoses, repairs, restarts, verifies |
| Reboot Windows with nobody logged in | Tailscale, SSH, WSL, UI, Gateway return automatically |
| Internet disconnected temporarily | services stay local; reconnect when internet returns |
| Stop the Tailscale Windows service | Windows service recovery restarts it |
| Disk filled to warning threshold | backup/repair avoid unsafe writes and report |
| Slack unavailable temporarily | notifications queue locally and retry |
| AI authentication expired | deterministic recovery continues; Slack reports AI repair unavailable |
| AI repair fails verification | changes roll back; new attempt after cooldown |

### 4.3 Success criteria

Complete only when **all** hold:

- Both operators can SSH into Windows over Tailscale and enter WSL.
- Both can open the OpenClaw UI through private HTTPS.
- Authorized clients can reach the authenticated Gateway.
- None of those interfaces are publicly accessible.
- A Windows reboot recovers everything without login or manual commands.
- The tested OpenClaw, WSL, configuration and dependency failures recover as designed.
- Slack receives useful incident and recovery summaries without routine noise.
- Secrets do not appear in git history, repair prompts, or normal logs.
- A failed AI repair rolls back cleanly.
- Backup **restoration** has been tested, not merely backup creation.

### 4.4 Recovery objectives

| Failure | Target |
|---|---|
| OpenClaw process failure | < 2 min |
| WSL failure | < 5 min |
| Configuration / dependency failure | < 20 min where the AI can diagnose it |
| Windows reboot | full availability within 5–10 min (hardware / updates dependent) |

---

## 5. On-laptop state layout

```
C:\openclaw-laptop-ops\                      REPO_DIR_WIN — this repo (immutable copy of the scripts)
C:\ProgramData\openclaw-ops\                 OPS_ROOT_WIN — ACL: WIN_USER, SYSTEM, Administrators
  state.json                                 phase, last heartbeat, failure counters, cooldown, repair counts
  supervisor.lock                            execution lock
  slack-queue.jsonl                          undelivered Slack messages
  logs\ops.log                               JSON-lines, all scripts
  secrets\slack.xml                          DPAPI webhook (WIN_USER only)
  backups\daily\  backups\weekly\  backups\wsl-export\
  snapshots\                                 mirror of WSL pre-repair snapshots
  reports\discovery-<ts>.md  reports\incident-<ts>\

/home/<WSL_USER>/.openclaw/                  OPENCLAW_HOME — openclaw.json (JSON5), .env (600)
/home/<WSL_USER>/.openclaw-ops/              runner state (git repo)
  health.json  repair.lock  ai.env (600, only if apikey)
  snapshots/<ts>/  repairs/<ts>/  last-known-good -> snapshots/<ts>
```

---

## 6. Facts verified against vendor docs (2026-08-28)

**OpenClaw**
- Default gateway port **18789**; resolution order `--port` → `OPENCLAW_GATEWAY_PORT` → `gateway.port` → 18789.
- `openclaw gateway install` creates the `systemd --user` unit `openclaw-gateway.service`; headless hosts need
  `export XDG_RUNTIME_DIR=/run/user/$(id -u)` and `sudo loginctl enable-linger $(whoami)`. WSL doc also installs `dbus-x11`.
- Health: `openclaw gateway status --require-rpc`, `openclaw health`, `openclaw doctor` (`--fix`), `openclaw config validate`, `openclaw logs --follow`.
- Config `~/.openclaw/openclaw.json` (JSON5; unknown keys or bad types make the gateway refuse to start). Secrets via env or `~/.openclaw/.env` (`OPENCLAW_GATEWAY_TOKEN`, `OPENCLAW_GATEWAY_PASSWORD`); `${VAR}` substitution in config strings; dotenv never overrides existing env.
- `gateway.auth.mode`: `token` | `password` | `trusted-proxy` | `none`. `gateway.bind`: `loopback` (default) | `lan` | `tailnet` | `custom`.
- `gateway.trustedProxies` required for a reverse proxy, else proxied connections are rejected on gateway-authenticated routes; proxy should **overwrite** `X-Forwarded-For`.
- `gateway.controlUi.allowedOrigins` required when the Control UI is served via a proxy under a different hostname.
- `gateway.auth.allowTailscale` resolves `x-forwarded-for` via the **local** `tailscale whois` — unusable when Serve runs on Windows.
- Tailscale automation `gateway.tailscale.mode`: `off` | `serve` | `funnel` — we keep `off` (Serve is Windows-managed).
- WSL auto-start (OpenClaw doc): `schtasks /create /tn "WSL Boot" /tr "wsl.exe -d <Distro> --exec dbus-launch true" /sc onstart /ru "<user>"` — `dbus-launch true` not `/bin/true` (WSL ≥ 2.6.1.0 idle termination); `/ru` the owning user, not SYSTEM.

**WSL**
- systemd: `/etc/wsl.conf` `[boot] systemd=true`, then `wsl --shutdown` (8-second rule). Verify `systemctl list-unit-files --type=service`.
- `.wslconfig` (`%UserProfile%\.wslconfig`, `[wsl2]`): `vmIdleTimeout` (ms, default 60000, Windows 11), `localhostForwarding` (default true; ignored when `networkingMode=mirrored`), `memory`, `networkingMode` (`nat` default | `mirrored`).
- `wsl --terminate <Distro>` stops one distro; `wsl --shutdown` stops all.

**Tailscale**
- `tailscale up --unattended=true --auth-key=tskey-… --hostname=<name> --advertise-tags=<tags>`; unattended keeps Tailscale connected with no user signed in (Windows).
- Auth keys: reusable / ephemeral / pre-approved / tags; tagged devices have key expiry disabled by default.
- `tailscale serve --bg --https=443 http://127.0.0.1:18789`; `tailscale serve status [--json]`; `tailscale serve reset`; `--bg` config persists across reboot/restart.
- Do not run Tailscale on Windows and inside WSL simultaneously (nested MTU problems).

**Windows OpenSSH**
- Install `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`; service `sshd`, `Set-Service -StartupType Automatic`.
- Config `%ProgramData%\ssh\sshd_config` (read at service start — restart after edits). Administrators' keys in `%ProgramData%\ssh\administrators_authorized_keys` with
  `icacls.exe "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"`.
- Default shell: `HKLM:\SOFTWARE\OpenSSH` string `DefaultShell` = `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`.
- `AllowGroups` / `AllowUsers` names must be **lowercase**; only `password` and `publickey` auth exist. Firewall rule created by install: `OpenSSH-Server-In-TCP` (we replace with the tailnet-scoped `OpenClawOps-SSH-Tailnet`).

**AI runners**
- Codex: `codex exec [--dangerously-bypass-approvals-and-sandbox | --sandbox workspace-write|danger-full-access | -a never] -C <dir> -m <model> --json -o <file>`; prompt from stdin with `codex exec - < prompt.txt`; `--full-auto` deprecated.
- Claude Code: `claude -p "<prompt>" --permission-mode bypassPermissions|acceptEdits|auto|dontAsk`, `--allowedTools`, `--output-format json|stream-json`, `--append-system-prompt`, `--continue/--resume`; **do not** use `--bare` (skips `CLAUDE.md`, never reads OAuth). Exit code non-zero on failure.
