# AGENTS.md — instruction layer for the on-site setup agent

You are a coding agent (Codex CLI or Claude Code) running **on the client's Windows laptop**, in an
**elevated PowerShell**, with this repository checked out at `REPO_DIR_WIN` (default `C:\openclaw-laptop-ops`).
A human (Ruh engineer) is watching over TeamViewer and can type at the console when you ask.

Your job: make OpenClaw (running inside WSL 2 on this laptop) remotely reachable over Tailscale,
self-healing, backed up, and reporting to Slack — by executing `RUNBOOK.md` phase by phase, using the
scripts in `windows/` and `wsl/`. You are not here to design; the design is done (`ARCHITECTURE.md`).

## Read order
1. This file.
2. `RUNBOOK.md` — find the **current phase** (`Get-Content C:\ProgramData\openclaw-ops\state.json` → `.phase`; if missing you are at Phase 0).
3. `config/site.env` — the machine facts. If it doesn't exist, Phase 0 creates it from `config/site.env.example`.
4. Only then the scripts for the current phase.

## Non-negotiable rules
1. **Phases run in order. Each phase ends with its gate passing** (`windows\90-verify.ps1 -Phase N`). Do not start
   phase N+1 while gate N fails. Do not skip phases because they "look done" — run the script; they are idempotent.
2. **Never break the access path.** After Phase 1, these are PROTECTED and you do not modify, stop, or reinstall them
   without the human typing `yes` at the console: Windows Tailscale (service, `tailscale up` args, Serve config),
   Windows OpenSSH (`sshd`, `%ProgramData%\ssh\*`), Windows Firewall rules named `OpenClawOps-*`, the scheduled tasks
   `OpenClawOps-*`, TeamViewer, and `windows\lib\Common.psm1`. The AI repair runner (`wsl/repair/`) is sandboxed to
   the `WSL_USER` Linux account and can't reach them; **you** can, so you must not.
3. **Secrets never touch this repo, logs, Slack, or your transcript.** Tailscale auth key, Slack webhook, gateway token,
   API keys, GitHub PAT (private forks only), Windows passwords: when a script needs one it prompts (`Read-Host -AsSecureString`) — hand the
   keyboard to the human. If you see a secret in output, do not repeat it.
4. **No reboots, `wsl --shutdown`, or WSL re-registration outside the steps that call for them** — and those steps
   require the human to confirm TeamViewer will survive it (Phase 1 gate proves SSH-over-Tailscale first).
5. **Idempotent, verify, log.** Every script: safe to re-run; verifies its own result; logs to
   `%OPS_ROOT_WIN%\logs\`. If a script fails, read the log, fix the *cause*, re-run the *same* script. Don't hand-patch
   the outcome (e.g. don't write `openclaw.json` by hand if `wsl/20-harden-config.sh` failed — fix why it failed).
6. **Verify on-site, don't assume.** Values marked `VERIFY-ON-SITE` in the runbook (distro name, WSL owner, proxy
   source IP as seen from WSL, tailnet suffix, WSL/Windows versions) come from discovery output, not from memory.
7. **Scope for tonight is Phases 0–4** (access, service, private UI, backups, supervisor in `observe` mode).
   `RECOVERY_MODE=restart` and `repair` are later sessions. Do not enable them tonight even if asked casually;
   the escalation ladder needs 24h of clean observation first (see RUNBOOK "Later").
8. **When blocked, stop and say exactly what you need** — a value, a keypress, a decision. Mark it
   `[HUMAN AT CONSOLE]`. Don't guess your way past a prompt.

## How to run things
- Windows scripts: `powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\<script>.ps1 [-Params]` from the repo root, elevated.
- WSL scripts are launched **from Windows** via the wrapper so they run as the right Linux user with the repo mounted:
  `.\windows\Invoke-WslScript.ps1 -Script wsl/healthcheck.sh [-Args ...]`
  (equivalent to `wsl.exe -d $DISTRO -u $WSL_USER -- bash /mnt/c/openclaw-laptop-ops/wsl/healthcheck.sh`).
- Read state: `.\windows\90-verify.ps1 -Phase <n>` (prints PASS/FAIL per check, exit code 0 on pass).
- Read logs: `Get-Content -Tail 100 C:\ProgramData\openclaw-ops\logs\ops.log`
- Everything you need to know about the machine after Phase 0 is in `C:\ProgramData\openclaw-ops\reports\discovery-*.md`.

## Reporting back
At the end of each phase, print a short block:
```
PHASE <n> <PASS|FAIL>
changed: <what you changed, one line each>
verified: <gate checks that passed>
open: <anything needing the human or the next session>
```
Then stop and wait for the human to say "continue".

## What "done tonight" means
- Both operators can `ssh <WIN_USER>@<TS_HOSTNAME>` over Tailscale and `wsl -d <DISTRO>` from there.
- `https://<TS_HOSTNAME>.<TS_TAILNET>/` loads the OpenClaw Control UI from a second tailnet device and pairs with the token.
- `openclaw gateway status --require-rpc` passes inside WSL; the gateway is a systemd user service with linger.
- A Windows reboot with nobody logged in brings Tailscale, SSH, WSL, systemd, gateway, and Serve back — **tested once, live, with TeamViewer as the safety net.**
- Scheduled tasks exist: WSL boot, supervisor (every minute, `observe`), nightly backup, weekly WSL export; first backup + export succeeded.
- Slack received "system available" from the supervisor.
- TeamViewer is still installed and running.
