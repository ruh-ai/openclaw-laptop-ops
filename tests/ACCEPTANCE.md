# Acceptance tests — fault injection matrix

Every row: what to break, the exact command to break it, what must happen, how to prove it, the
target time, the `RECOVERY_MODE` (`config/site.env`) the test needs, and whether it may run
**TONIGHT**. Tonight-safe = needs no supervisor recovery action (systemd's own `Restart=` counts
as "no action") or is a pure observation test. Anything that needs `restart` or `repair` mode is
**LATER** — running it tonight in `observe` mode would just produce an outage and a Slack alert.

Conventions:
- `PS>` = elevated PowerShell on Windows, cwd `C:\openclaw-laptop-ops`.
- WSL commands run through the wrapper: `PS> .\windows\Invoke-WslScript.ps1 -Script tests/inject/<name>.sh`
  (runs as `WSL_USER` inside `DISTRO`).
- Verify helper: `PS> .\windows\90-verify.ps1 -Phase 4` prints PASS/FAIL per check. `-Watch` re-runs every 15 s.
- Watch the supervisor: `PS> Get-Content -Wait -Tail 50 C:\ProgramData\openclaw-ops\logs\ops.log`
- Every injector has an inverse (listed). **Always run the inverse**, even if recovery succeeded.
- Before any test: `PS> .\windows\90-verify.ps1 -Phase 4` must PASS, and note the time.

Injector scripts referenced (in `tests/inject/`): `kill-gateway.sh`, `crashloop-gateway.sh`,
`break-config.sh`, `break-dependency.sh`, `restore-config.sh`, `Stop-Wsl.ps1`, `Stop-Tailscale.ps1`,
`Fill-Disk.ps1`, `Block-Slack.ps1`.

---

## 0. Gate test — Reboot Windows with nobody logged on

This is the **Phase 1 gate** (access survives reboot, before WSL work) and again the **Phase 4 gate**
(everything comes back). It is the only test that can lock us out, so it has a pre-check list.

**Pre-checks (all must be true, human confirms each at the console):**
- [ ] TeamViewer is installed, running, set to start with Windows, and unattended access password is known.
- [ ] `PS> tailscale status` shows the laptop online; both operators appear in the tailnet.
- [ ] From an operator machine: `ssh <WIN_USER>@<TS_HOSTNAME>` works with key auth **right now**.
- [ ] `PS> Get-ScheduledTask OpenClawOps-*` lists `OpenClawOps-WslBoot` and `OpenClawOps-Supervisor` as Ready (Phase 4 only).
- [ ] `PS> tailscale serve status` shows the HTTPS route (Phase 3+ only).
- [ ] A human is at (or can get to) the console via TeamViewer if the machine does not come back.
- [ ] Note the time: `PS> Get-Date -Format o`

**Inject:** `PS> Restart-Computer -Force` (do **not** log in when it comes back — wait).

**Expected:** within 5–10 min: Tailscale online → SSH reachable → (Phase 4) WSL running → systemd →
`openclaw-gateway.service` active → Serve route → UI loads → Slack "system available" from the supervisor.

**Verify (from an operator machine, nobody logged in on the laptop):**
```
ssh <WIN_USER>@<TS_HOSTNAME> "tailscale status; wsl -l --running"
ssh <WIN_USER>@<TS_HOSTNAME> "wsl -d <DISTRO> -u <WSL_USER> -- systemctl --user is-active openclaw-gateway.service"
ssh <WIN_USER>@<TS_HOSTNAME> "wsl -d <DISTRO> -u <WSL_USER> -- openclaw gateway status --require-rpc"
# browser on operator machine: https://<TS_HOSTNAME>.<TS_TAILNET>/  → Control UI loads, pairs with token
ssh <WIN_USER>@<TS_HOSTNAME> "powershell -File C:\openclaw-laptop-ops\windows\90-verify.ps1 -Phase 4"
```
Slack must show exactly one "system available" (and, on the Phase 4 run, no "availability gap" longer than the reboot itself).

| Target | Mode | Tonight |
|---|---|---|
| Phase 1 gate: SSH over Tailscale back < 5 min · Phase 4 gate: full chain < 10 min | any (`observe` is fine — boot task is not a "recovery action") | **YES — required tonight, twice (after Phase 1 and after Phase 4)** |

If the laptop does not come back on Tailscale within 10 minutes: TeamViewer in, log in, run
`PS> .\windows\00-discovery.ps1` and `PS> .\windows\90-verify.ps1 -Phase 1`, read `ops.log`. Do not start Phase 2 until this passes.

---

## 1. Matrix

### 1.1 Stop the OpenClaw Gateway (single crash)

| | |
|---|---|
| Inject | `PS> .\windows\Invoke-WslScript.ps1 -Script tests/inject/kill-gateway.sh` (sends SIGKILL to the gateway process once) |
| Expected | `openclaw-gateway.service` `Restart=` policy restarts it. Supervisor sees at most one failed cycle (< `CONFIRM_FAILURES`), logs it, **no Slack** (no confirmed failure). |
| Verify | `PS> .\windows\Invoke-WslScript.ps1 -Script wsl/healthcheck.sh` → `ok`; `wsl -d <DISTRO> -u <WSL_USER> -- systemctl --user show openclaw-gateway.service -p NRestarts` increments by 1 |
| Target | < 2 min |
| Mode | `observe` (systemd does the work) |
| Tonight | **YES** |
| Inverse | none needed |

### 1.2 Kill the OpenClaw process repeatedly (restart loop)

| | |
|---|---|
| Inject | `PS> .\windows\Invoke-WslScript.ps1 -Script tests/inject/crashloop-gateway.sh` (kills the gateway every 10 s for 3 min, backgrounded; prints its own PID) |
| Expected | systemd hits `StartLimitBurst`; supervisor confirms failure after `CONFIRM_FAILURES` cycles → Slack "failure detected" → **escalates** (`restart` mode: restart gateway → restart WSL; `repair` mode: continues to rollback → AI). In `observe`: Slack "failure detected" only. |
| Verify | `ops.log` shows `failure-confirmed` then the ladder steps; after the injector stops, `STABILIZATION_CYCLES` healthy cycles → Slack "recovered" |
| Target | escalation begins within `CONFIRM_FAILURES` + 1 min; recovered < 5 min after injector exits |
| Mode | `restart` for the escalation to act; in `observe` this only tests detection + Slack |
| Tonight | **NO** (produces a 3-minute outage and a Slack alert with no recovery; run in the `restart`-mode session) |
| Inverse | `kill <pid printed by injector>` via `Invoke-WslScript -Script tests/inject/kill-gateway.sh -Args --stop-loop`; then `systemctl --user reset-failed openclaw-gateway.service` |

### 1.3 Terminate the WSL distribution

| | |
|---|---|
| Inject | `PS> .\tests\inject\Stop-Wsl.ps1` (`wsl --terminate <DISTRO>`, only this distro) |
| Expected | Supervisor's "WSL running" check fails; after `CONFIRM_FAILURES` → `restart` mode: starts the distro (`wsl -d <DISTRO> --exec dbus-launch true`), waits for systemd, verifies gateway RPC → Slack "recovery step started" / "recovered". |
| Verify | `PS> wsl -l --running` includes `<DISTRO>`; `PS> .\windows\90-verify.ps1 -Phase 2` PASS |
| Target | < 5 min |
| Mode | `restart` |
| Tonight | **NO** — but a **manual** variant is tonight-safe: run `Stop-Wsl.ps1`, then `PS> Start-ScheduledTask OpenClawOps-WslBoot`, and verify the boot task alone brings WSL + gateway back (this proves the Phase 4 boot task without needing recovery mode). |
| Inverse | `PS> Start-ScheduledTask OpenClawOps-WslBoot` if recovery didn't run |

### 1.4 Introduce an invalid OpenClaw configuration

| | |
|---|---|
| Inject | `PS> .\windows\Invoke-WslScript.ps1 -Script tests/inject/break-config.sh` (snapshots first via `wsl/snapshot.sh`, then writes an unknown key + bad type into `openclaw.json`, restarts the unit — gateway refuses to start) |
| Expected | Restart tier fails (config still invalid) → rollback tier: `wsl/rollback.sh` restores last-known-good → verify passes → Slack "recovered (rollback)". In `repair` mode, if rollback were unavailable, AI repair fixes the config. |
| Verify | `openclaw config validate` passes; `openclaw gateway status --require-rpc` ok; `~/.openclaw-ops/last-known-good` unchanged; `ops.log` shows `rollback` step |
| Target | < 5 min (rollback) · < 20 min (AI) |
| Mode | `restart` (rollback is in the restart tier) · `repair` for the AI path |
| Tonight | **NO** |
| Inverse | `PS> .\windows\Invoke-WslScript.ps1 -Script tests/inject/restore-config.sh` (restores the snapshot the injector made — run it if recovery didn't) |

### 1.5 Break a dependency

| | |
|---|---|
| Inject | `PS> .\windows\Invoke-WslScript.ps1 -Script tests/inject/break-dependency.sh` (snapshots, then removes/corrupts one runtime dependency of the gateway so it crashes at start with a clear module error) |
| Expected | Restart and WSL-restart tiers fail; rollback does **not** fix it (dependency is outside the config snapshot) → AI repair runner invoked (Slack "AI repair invoked") → diagnoses from journal, reinstalls/repairs, restarts, `verify.sh` passes → Slack "recovered" with the change record. |
| Verify | `openclaw gateway status --require-rpc` ok; `~/.openclaw-ops/repairs/<ts>/` contains before/after diagnostics + change record; `git -C ~/.openclaw-ops log -1` shows the repair commit; nothing under the protected paths changed |
| Target | < 20 min |
| Mode | `repair` |
| Tonight | **NO** |
| Inverse | `PS> .\windows\Invoke-WslScript.ps1 -Script tests/inject/restore-config.sh -Args --with-deps` (reinstalls from the snapshot's recorded versions) |

### 1.6 Reboot Windows with nobody logged in

See §0 — this is the gate test. Tonight: **YES**, required.

### 1.7 Temporarily disconnect internet

| | |
|---|---|
| Inject | Physically: unplug Ethernet / turn Wi‑Fi off from the console for 3 minutes. (No script — the test is about the physical link.) `[HUMAN AT CONSOLE]` |
| Expected | Gateway keeps running (local); Tailscale goes offline; supervisor logs `internet: down`, queues Slack messages in `slack-queue.jsonl`, takes **no recovery action** (internet loss is not a service failure). When the link returns: Tailscale reconnects, Serve route resumes, queued Slack messages flush in order. |
| Verify | during: `PS> tailscale status` offline, `Get-Content C:\ProgramData\openclaw-ops\slack-queue.jsonl` non-empty; after: queue empty, Slack shows the queued messages, `PS> .\windows\90-verify.ps1 -Phase 4` PASS |
| Target | reconnect < 2 min after link returns |
| Mode | `observe` |
| Tonight | **YES** (short, physical, with TeamViewer reconnecting after) — optional if time is short |
| Inverse | reconnect the link |

### 1.8 Stop the Tailscale Windows service

| | |
|---|---|
| Inject | `PS> .\tests\inject\Stop-Tailscale.ps1` (`Stop-Service Tailscale`; **you will lose SSH/Serve until it restarts — run from TeamViewer, never over SSH**) |
| Expected | Windows service recovery (configured by `windows/10-tailscale.ps1`: restart on failure) restarts it; Serve route resumes on its own. Supervisor logs the blip; Slack "failure detected"/"recovered" only if it lasted ≥ `CONFIRM_FAILURES` cycles. |
| Verify | `PS> Get-Service Tailscale` Running; `PS> tailscale serve status` shows the route; UI loads from an operator machine |
| Target | < 2 min |
| Mode | `observe` (Windows SCM does the work) |
| Tonight | **YES — only via TeamViewer**, and only after §0 Phase 1 gate passed |
| Inverse | `PS> Start-Service Tailscale` if SCM recovery did not fire (then fix the recovery config before continuing) |

### 1.9 Fill disk to the warning threshold

| | |
|---|---|
| Inject | `PS> .\tests\inject\Fill-Disk.ps1` (creates `%OPS_ROOT_WIN%\TEST-filldisk.bin` with `fsutil file createnew` sized to push C: to `DISK_WARN_PCT`+1 % (allocated bytes, not sparse — the OS sees the pressure); prints the size) |
| Expected | Supervisor's disk check → Slack "disk warning"; `Backup-OpenClaw.ps1` and `Export-Wsl.ps1` refuse to write (`MIN_FREE_GB_FOR_EXPORT`) and report; repair runner refuses to start (`repair` mode) and reports "repair blocked: disk". No crash, no half-written backup. |
| Verify | trigger `PS> Start-ScheduledTask OpenClawOps-BackupNightly` → `ops.log` shows `backup skipped: disk`; no new file in `backups\daily\`; Slack has the warning |
| Target | warning within one supervisor cycle |
| Mode | `observe` |
| Tonight | **YES** — **only if** C: has ≥ 20 GB free so the dummy file is a few GB, not tens; **delete the file immediately after** |
| Inverse | `PS> .\tests\inject\Fill-Disk.ps1 -Cleanup` — **mandatory** |

### 1.10 Make Slack temporarily unavailable

| | |
|---|---|
| Inject | `PS> .\tests\inject\Block-Slack.ps1` (adds `127.0.0.1 hooks.slack.com` to `C:\Windows\System32\drivers\etc\hosts`, flushes DNS; `-Revert` removes it) |
| Expected | Supervisor's next state-change message fails to deliver → appended to `slack-queue.jsonl`, retried each cycle; no exception, no repeated duplicate. After revert, queue flushes once, in order. |
| Verify | force a message: `PS> .\windows\supervisor\Supervisor.ps1 -TestSlack` → `slack-queue.jsonl` has 1 line; revert; next cycle → queue empty and the test message arrives once in Slack |
| Target | delivery within one supervisor cycle after revert |
| Mode | `observe` |
| Tonight | **YES** |
| Inverse | `PS> .\tests\inject\Block-Slack.ps1 -Revert` — **mandatory** |

### 1.11 Expire AI authentication

| | |
|---|---|
| Inject | as `WSL_USER`: `codex logout` (or move `~/.codex/auth.json` aside) and `claude logout` / move `~/.claude/.credentials.json` aside — `[HUMAN AT CONSOLE]` (never delete; move to `~/.openclaw-ops/auth-backup/`) |
| Expected | Supervisor's periodic "AI repair-agent auth" probe fails → Slack "AI repair unavailable (auth)"; deterministic tiers still run; a fault that reaches the AI tier ends in "recovery failed, cooldown" instead of an AI attempt. |
| Verify | `ops.log` / `HealthCheck.ps1 -Deep` shows `ai.auth` WARN with `codex: NOT authenticated` / `claude: NOT authenticated`; Slack has the notice; `PS> .\windows\90-verify.ps1 -Phase 5` shows `ai.auth` FAIL and everything else PASS |
| Target | notice within the probe interval |
| Mode | `repair` (only meaningful once AI repair is enabled) |
| Tonight | **NO** |
| Inverse | restore the moved credential files / `codex login`, `claude login` — `[HUMAN AT CONSOLE]` |

### 1.12 Make an AI repair fail verification

| | |
|---|---|
| Inject | `PS> .\windows\Invoke-WslScript.ps1 -Script tests/inject/break-dependency.sh -Args --unfixable` (breaks the dependency **and** places a `~/.openclaw-ops/TEST-FORCE-VERIFY-FAIL` marker that `wsl/repair/verify.sh` honours to return failure regardless of state) |
| Expected | AI attempt 1 → `verify.sh` fails → `wsl/rollback.sh` restores the pre-attempt snapshot → attempt 2, 3 (each from a fresh snapshot) → limit `MAX_AI_REPAIRS_PER_HOUR` reached → Slack "recovery failed, cooldown started"; safe restarts continue during `AI_COOLDOWN_MIN`; no partial changes left behind. |
| Verify | `~/.openclaw-ops/repairs/` has 3 attempt dirs each with `rolled-back=true`; `state.json` `.ai.cooldownUntil` set; config + unit hash equal the pre-attempt snapshot; after removing the marker and restoring the dependency, the next cycle recovers |
| Target | 3 attempts + cooldown entry < 1 h |
| Mode | `repair` |
| Tonight | **NO** |
| Inverse | remove the marker; `PS> .\windows\Invoke-WslScript.ps1 -Script tests/inject/restore-config.sh -Args --with-deps`; clear cooldown: `PS> .\windows\supervisor\Supervisor.ps1 -ClearCooldown` |

---

## 2. Tonight's run order

1. §0 reboot gate — **after Phase 1** (Tailscale + SSH only).
2. Phases 2–4 per `RUNBOOK.md`.
3. §1.1 single gateway kill.
4. §1.3 manual variant (terminate WSL → `Start-ScheduledTask OpenClawOps-WslBoot`).
5. §1.10 Slack block + revert.
6. §1.8 Tailscale stop — **from TeamViewer only**.
7. §1.9 disk fill — only with ≥ 20 GB free; delete the file.
8. §1.7 internet unplug — optional.
9. §0 reboot gate — **after Phase 4** (full chain, nobody logged in).
10. Confirm `RECOVERY_MODE=observe` is still set and Slack got exactly one "system available".

Everything marked LATER runs in the `restart`-mode session (after ≥ 24 h of clean observe) and the
`repair`-mode session after that.

---

## 3. Success criteria (the setup is complete only when all hold)

- Both operators can SSH into Windows over Tailscale and enter WSL.
- Both can open the OpenClaw UI through private HTTPS.
- Authorized clients can reach the authenticated Gateway.
- None of those interfaces are publicly accessible (verified from a non-tailnet network: connection refused / no DNS).
- A Windows reboot recovers everything without login or manual commands.
- The tested OpenClaw, WSL, configuration, and dependency failures recover as designed.
- Slack receives useful incident and recovery summaries without routine noise.
- Secrets do not appear in git history, repair prompts, or normal logs (`git log -p | grep -iE 'tskey|hooks.slack|OPENCLAW_GATEWAY_TOKEN=' ` is empty; `ops.log` grep is empty).
- A failed AI repair rolls back cleanly.
- Backup **restoration** has been tested, not merely backup creation (restore a nightly backup into a scratch dir and diff; `wsl --import` the weekly export as `<DISTRO>-restoretest`, start it, `openclaw config validate`, then unregister it).

## 4. Recovery objectives

| Failure | Target |
|---|---|
| OpenClaw process failure | under 2 minutes |
| WSL failure | under 5 minutes |
| Configuration / dependency failure | under 20 minutes where the AI can diagnose it |
| Windows reboot | full availability within 5–10 minutes, depending on hardware and updates |
