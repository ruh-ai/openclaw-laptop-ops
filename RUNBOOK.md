# RUNBOOK — OpenClaw laptop: access, self-healing, backups

Executed by an agent (Codex or Claude Code) in an **elevated PowerShell on the laptop**, repo root as cwd, human on TeamViewer.
Rules: `AGENTS.md`. Design: `ARCHITECTURE.md`. Tests: `tests/ACCEPTANCE.md`. Machine facts: `config/site.env`.

| Phase | Name | Gate | When |
|---|---|---|---|
| 0 | Discovery + safety snapshot | `site.env` reviewed by human; discovery report saved | TONIGHT |
| 1 | Remote access: Tailscale + SSH (Windows) | `90-verify.ps1 -Phase 1` incl. SSH from a 2nd tailnet device | TONIGHT |
| 2 | WSL runtime: systemd + OpenClaw service | `90-verify.ps1 -Phase 2` | TONIGHT |
| 3 | Private UI: Tailscale Serve + hardened gateway | `90-verify.ps1 -Phase 3` incl. UI pairs from a 2nd device | TONIGHT |
| 4 | Supervision (observe), power, backups, **reboot test** | `90-verify.ps1 -Phase 4` + live reboot recovers | TONIGHT |
| 5 | Escalate: `restart` mode → `repair` mode + fault tests | `90-verify.ps1 -Phase 5` + `tests/ACCEPTANCE.md` LATER rows | LATER (≥24h observe) |

## FAST PATH (recommended) - three commands, ~30-60 min wall clock, one place where you type secrets
```powershell
# 1. elevated PowerShell, as the Windows account that owns the WSL distro
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/ruh-ai/openclaw-laptop-ops/main/windows/bootstrap.ps1 | iex
cd C:\openclaw-laptop-ops
.\windows\Start-Run.ps1          # 2. intake: SITE_NAME, TS_HOSTNAME, Tailscale auth key, Slack webhook, Windows password - typed once, hidden
codex --dangerously-bypass-approvals-and-sandbox      # 3. or: claude --dangerously-skip-permissions
# > Autonomous mode. Run .\windows\Run-All.ps1 -Reboot and fix anything that stops it.
```
`Run-All.ps1` runs Phases 0-4 below without pausing, auto-gates each phase, auto-verifies SSH (self-connect over the tailnet IP) and the UI (HTTP on TS_URL) from the laptop, registers the tasks with the stored password (then deletes it), takes the first backup + export, runs a restore test, and with `-Reboot` restarts Windows so the boot sequence is proven while you are still on TeamViewer. The second-device checks (SSH from your Mac, pair the UI) are printed as a **post-run checklist** - do them while the laptop reboots. If a gate fails it prints the FAIL lines and the resume command (`Run-All.ps1 -From N`).
Pre-call prep is unchanged (below). The phase-by-phase procedure that follows is the fallback / reference for fixing a failed gate.

---

Every script prints `PHASE n PASS|FAIL / changed / verified / open`. In the fast path Run-All handles this; in phase-by-phase mode, stop after each phase and wait for "continue".
`[HUMAN AT CONSOLE]` = hand over the keyboard. Never type secrets yourself.

---

## Before the call (Ruh engineer, on your own machine) - in this order
- [ ] **Operator SSH public keys committed** under `config/operators/` (needed before the laptop clones):
      `cp ~/.ssh/id_ed25519.pub config/operators/prasanjit.pub` (plus the second developer's key) -> commit -> push. Public keys only.
- [ ] Tailscale admin console: **MagicDNS on**, **HTTPS certificates on** (DNS tab); ACL includes `tag:openclaw-laptop` + operators (see `config/tailscale-acl.example.hujson`); generate an **auth key**: reusable=no, ephemeral=no, pre-approved=yes, tags=`tag:openclaw-laptop`. Keep it in your password manager; you'll type it once.
- [ ] Both operators' SSH public keys committed under `config/operators/` (see its README).
- [ ] Slack: create an incoming webhook for the alert channel. Keep the URL ready to type.
- [ ] Know the laptop's Windows username/password owner (the client must type the password for scheduled tasks).
- [ ] Decide `RECOVERY_MODE` stays `observe` tonight (it does).

## Phase 0 — Bootstrap + discovery (read-only except report files)  TONIGHT
1. Human on TeamViewer opens **PowerShell as Administrator** and pastes:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   irm https://raw.githubusercontent.com/ruh-ai/openclaw-laptop-ops/main/windows/bootstrap.ps1 | iex
   ```
   (The repo is public: no token needed. If you are using a **private fork**, add `-Headers @{Authorization="Bearer $(Read-Host 'GitHub PAT')"}` to `irm`;
   bootstrap then prompts for the same read-only PAT for `git clone` and strips it from the remote URL. Both schemes were verified 2026-08-28.)
   Fallback if `irm` is blocked: copy `windows\bootstrap.ps1` via TeamViewer file transfer and run `powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1`.
2. `cd C:\openclaw-laptop-ops` then start the agent: `codex` (or `claude`). First prompt: *"Read AGENTS.md and RUNBOOK.md. We are at Phase 0. Go."*
3. Agent: `.\windows\00-discovery.ps1 -WriteSiteEnv` → read the report path it prints; open `config\site.env` and verify each `VERIFY-ON-SITE` value against the report:
   `WIN_USER` (must own the distro — `wsl.registryOwner`), `DISTRO` (exact), `WSL_USER`/`OPENCLAW_HOME`/`OPENCLAW_INSTALL_METHOD` (existing install? which user owns `~/.openclaw`?), `TS_HOSTNAME` (choose), `SITE_NAME`.
   If OpenClaw is already installed under a different Linux user than `WSL_USER`, set `WSL_USER` to that user — do not migrate tonight.
4. Safety snapshot before any change: `.\windows\backup\Export-Wsl.ps1` (full distro export; needs `MIN_FREE_GB_FOR_EXPORT`) and, if OpenClaw exists, `.\windows\Invoke-WslScript.ps1 -Script wsl/snapshot.sh` (config snapshot — WSL_USER must exist; skip if not).
   If systemd is not PID 1 yet, `snapshot.sh` still works (it only tars files).
5. Human reviews `site.env`. **Gate 0:** human says "site.env is right".

## Phase 1 — Remote access (Windows)  TONIGHT   *TeamViewer stays on until Phase 4's reboot test passes*
1. `.\windows\10-tailscale.ps1` → `[HUMAN AT CONSOLE]` pastes the auth key. Script prints tailnet IPv4 + MagicDNS suffix and writes `TS_TAILNET` into `site.env`. If the device name isn't `TS_HOSTNAME`, fix in admin console or `site.env`.
   Windows Firewall may prompt for `tailscale.exe`/`tailscaled` — allow.
2. `.\windows\11-openssh.ps1` (password auth still ON). Then **from a second tailnet device**: `ssh <WIN_USER>@<TS_HOSTNAME>` → PowerShell prompt → `wsl -d <DISTRO> -- echo ok`.
3. Key login confirmed → `.\windows\11-openssh.ps1 -DisablePassword` → test SSH again.
4. `.\windows\90-verify.ps1 -Phase 1 -ConfirmRemoteSsh` (the flag records the human's confirmation of step 2/3). **Gate 1 must PASS.**
   From here on: Tailscale, sshd, firewall rules `OpenClawOps-*` are PROTECTED (AGENTS.md rule 2).

## Phase 2 — WSL runtime + OpenClaw service  TONIGHT
1. `.\windows\20-wsl-prepare.ps1` — writes `.wslconfig` (localhostForwarding, `WSL_VM_IDLE_TIMEOUT_MS`, memory), `/etc/wsl.conf` (`systemd=true`, default user), creates `WSL_USER` if missing (+ narrow sudoers), installs `dbus-x11`, enables linger, **restarts only this distro** (`wsl --terminate`, not `--shutdown`).
   VERIFY-ON-SITE: if PID 1 is still not systemd after the terminate, the human decides on `wsl --shutdown` (kills all distros) and re-runs.
   VERIFY-ON-SITE: `vmIdleTimeout=-1` is not documented as valid on every WSL build — the default in `site.env` is 3600000 ms (1h); the WSLBoot task + systemd keep the VM busy anyway.
2. `.\windows\21-wsl-openclaw.ps1` — runs `wsl/10-openclaw-service.sh` (install if needed, `openclaw gateway install`, restart-policy drop-in, health timer) and `wsl/20-harden-config.sh --origin=<TS_URL>` (token → `~/.openclaw/.env` 600, `auth.mode=token`, `bind=loopback`, `allowTailscale=false`, `controlUi.allowedOrigins=[TS_URL]`). Validates config before restart; restores on failure.
   If OpenClaw was already installed with `gateway.auth.token` in `openclaw.json`, the script moves it to `.env`. Existing sessions/memory are untouched.
3. `.\windows\90-verify.ps1 -Phase 2` — WSL running, PID1 systemd, service active, `gateway status --require-rpc` OK, linger, token file 600, `127.0.0.1:18789` reachable from Windows. **Gate 2 must PASS.**
   Common failure: port not reachable from Windows → `localhostForwarding` didn't apply (needs full VM restart: `wsl --shutdown`, human decision) or gateway bound to something other than loopback.

## Phase 3 — Private UI over Tailscale Serve  TONIGHT
1. `.\windows\12-tailscale-serve.ps1` → `tailscale serve --bg --https=443 http://127.0.0.1:18789`. First HTTPS cert can take ~1 min. Fails fast if HTTPS certs aren't enabled in the admin console.
2. **From a second tailnet device**, open `https://<TS_HOSTNAME>.<TS_TAILNET>/`. The Control UI must load. Pair with the gateway token — the **human** reads it at the console: `wsl -d <DISTRO> -u <WSL_USER> -- cat ~/.openclaw-ops/gateway-token.txt` (agent: do not echo the token).
3. VERIFY-ON-SITE — proxy source address. If the UI loads but the WebSocket/pairing is rejected with a proxy/origin error:
   `.\windows\Invoke-WslScript.ps1 -Script wsl/healthcheck.sh` then read the journal for the rejected peer address:
   `wsl -d <DISTRO> -u <WSL_USER> -- journalctl --user -u openclaw-gateway.service -n 100 --no-pager | Select-String -Pattern 'proxy|origin|forward'`
   Expected candidates: `127.0.0.1` (localhost forwarding rewrites the source) or the WSL NAT host address (`ip route | grep default` inside WSL — e.g. `172.x.x.1`). Then:
   `.\windows\21-wsl-openclaw.ps1 -SkipInstall -ProxySource <observed-ip>` and retry pairing. Record the observed value in the discovery report.
   If the NAT address is what the gateway sees, note that it can change across WSL restarts — the supervisor's deep check (`gateway.http.tailnet`) will catch a break; the LATER fix is mirrored networking or a `trustedProxies` CIDR.
4. `.\windows\90-verify.ps1 -Phase 3 -ConfirmUiPaired`. **Gate 3 must PASS.** Confirm the URL is NOT reachable from a device outside the tailnet (phone on mobile data).

## Phase 4 — Supervision (observe), power, backups, reboot test  TONIGHT
1. **As `WIN_USER`** (same account the tasks run as — DPAPI): `.\windows\secrets\Set-OpsSecret.ps1 -Name slack` → `[HUMAN AT CONSOLE]` pastes the webhook. A test message must arrive in Slack.
2. `.\windows\40-power.ps1` — no sleep/hibernate on AC, lid does nothing on AC, NIC power saving off, fast startup off, update active hours 08–18. (BIOS "power on after AC loss": human, optional.)
3. `.\windows\30-startup-task.ps1` → `[HUMAN AT CONSOLE]` types `WIN_USER`'s Windows password once (Task Scheduler stores it; tasks run before login). Registers `OpenClawOps-WSLBoot`, `-Supervisor` (1 min, `observe`), `-BackupNightly`, `-WslExportWeekly`; runs the supervisor once.
4. First backups: `.\windows\backup\Backup-OpenClaw.ps1` then `.\windows\backup\Export-Wsl.ps1` (export already done in Phase 0 counts if nothing changed since — re-run anyway; ~minutes).
   Restore test (required by success criteria, cheap version): `.\windows\Invoke-WslScript.ps1 -Script wsl/snapshot.sh -Args --mark-good` then `.\windows\Invoke-WslScript.ps1 -Script wsl/rollback.sh -Args last-known-good` → must print `rolled back` and health OK.
5. `.\windows\90-verify.ps1 -Phase 4` → all PASS (RECOVERY_MODE must be `observe`).
6. **Reboot test** `[HUMAN AT CONSOLE]` — pre-checks: TeamViewer running and set to start with Windows; Gate 1 passed (SSH over Tailscale works); nobody needs the laptop for 10 min.
   On a **second device** run nothing yet; on the laptop: `Restart-Computer -Force`. From the second device: wait ~3 min, then `ssh <WIN_USER>@<TS_HOSTNAME>` **without anyone logging into Windows**, then in that SSH session `cd C:\openclaw-laptop-ops; .\windows\90-verify.ps1 -Phase 4 -Watch` until PASS. Slack must show "System available".
   Target: full availability ≤ 10 min. If SSH never comes back: TeamViewer → log in → `Get-Service Tailscale,sshd`; `Get-ScheduledTaskInfo OpenClawOps-WSLBoot`; `Get-Content C:\ProgramData\openclaw-ops\logs\ops.log -Tail 50`.
7. Print the Phase 4 block. **Tonight is done.** Leave TeamViewer installed and running as the emergency fallback (architecture decision).

## Later — Phase 5 (separate sessions, over Tailscale SSH)
- After ≥24h of clean `observe` (no false alarms in Slack, `state.json` incidents empty): set `RECOVERY_MODE=restart` in `site.env` (`git pull` on the laptop if you changed it in the repo — `site.env` is gitignored, edit it on the laptop). Run tonight-safe + `restart`-mode rows of `tests/ACCEPTANCE.md`.
- Then AI repair: on the laptop as `WSL_USER`: `codex login` (or `claude` → `/login`), or `AI_AUTH_MODE=apikey` with keys in `~/.openclaw-ops/ai.env` (600). `.\windows\90-verify.ps1 -Phase 5` → set `RECOVERY_MODE=repair`. Run the `repair` rows (break-config, break-dependency, unfixable → rollback + cooldown).
- Hardening backlog (not tonight): dedicated `openclaw-repair` Linux user so the repair runner cannot read `~/.openclaw/.env` (today it runs as `WSL_USER`, same account as the gateway — documented deviation from ARCHITECTURE "AI isolation"); mirrored WSL networking if the NAT proxy address proves unstable; Windows Update maintenance window policy; second Windows account per operator.

## If something goes wrong tonight
| Symptom | Do |
|---|---|
| `tailscale up` prints a login URL | human opens it, approves device, re-run `10-tailscale.ps1` |
| Serve: "HTTPS not enabled" | admin console → DNS → enable HTTPS certificates; re-run `12-tailscale-serve.ps1` |
| `wsl --terminate` didn't give systemd | human: `wsl --shutdown` (all distros) then re-run `20-wsl-prepare.ps1` |
| `wsl --install -d Ubuntu-24.04` says "Invalid distribution name" or "parameter is incorrect" | old in-box WSL (Server 2022 / older Win10): `wsl --install --no-distribution --web-download`, reboot, verify `wsl --version` works, then `wsl --install -d Ubuntu-24.04 --no-launch` (dry-run-verified 2026-08-28) |
| `openclaw gateway install` fails | check `openclaw doctor`; older OpenClaw → `wsl/10-openclaw-service.sh` needs `OPENCLAW_INSTALL_METHOD=npm` + `npm i -g openclaw@latest` (human decision to upgrade) |
| Gate 2: port not reachable from Windows | `wsl --shutdown` to apply `.wslconfig`; confirm `bind=loopback`; check Windows Firewall isn't blocking loopback (it doesn't) |
| UI loads, pairing rejected | Phase 3 step 3 (trustedProxies) |
| Scheduled task fails with 0x800710E0 / logon failure | password typo or "log on as batch job" right missing for `WIN_USER`: `secpol.msc` → User Rights → Log on as a batch job |
| Slack test never arrives | `Set-OpsSecret.ps1` was run as another account (DPAPI) — re-run as `WIN_USER`; or outbound HTTPS blocked |
| Lost all remote access after reboot | TeamViewer. Then `Start-Service Tailscale, sshd`; `tailscale status`; check `OpenClawOps-WSLBoot` last result |
