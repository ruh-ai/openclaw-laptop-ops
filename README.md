# openclaw-laptop-ops

Make an OpenClaw gateway running in **WSL 2 on a client's Windows laptop** remotely reachable (Tailscale), self-healing
(Windows supervisor + systemd + staged recovery + AI repair), backed up, and reporting to Slack — **laptop-only, no external VPS**.

This repo is the **instruction layer for a coding agent** (Codex CLI or Claude Code) that runs on the laptop with a human
watching over TeamViewer. Humans read `ARCHITECTURE.md`; agents read `AGENTS.md` then `RUNBOOK.md`.

```
AGENTS.md / CLAUDE.md   rules for the on-site agent (protected paths, secrets, phase gates)
RUNBOOK.md              phases 0-4 tonight, 5 later; every command; gates; troubleshooting
ARCHITECTURE.md         the design (option 2: layered supervisor with AI repair) + vendor-doc facts
config/site.env.example machine facts contract -> config/site.env (gitignored) on the laptop
windows/                PowerShell: bootstrap, discovery, tailscale, openssh, serve, wsl prep, tasks, power, verify, supervisor, backup
wsl/                    bash (as WSL_USER): openclaw service, config hardening, health, snapshot/rollback, AI repair runner
tests/                  acceptance matrix + fault injectors
```

## Start (on the laptop, elevated PowerShell)
```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
irm https://raw.githubusercontent.com/ruh-ai/openclaw-laptop-ops/main/windows/bootstrap.ps1 | iex
cd C:\openclaw-laptop-ops
codex   # or: claude
# > Read AGENTS.md and RUNBOOK.md. We are at Phase 0. Go.
```

## Principles
- Tailscale + SSH live on **Windows**; never a second Tailscale inside WSL. WSL is reached via Windows.
- The gateway stays on `127.0.0.1:18789` with **token auth**; Windows Tailscale Serve publishes it privately over HTTPS.
- Recovery is staged: restart service → restart WSL → rollback config → AI repair (Codex/Claude) → verify → cooldown. Enabled in steps: `observe` → `restart` → `repair`.
- The AI repair runner can't touch the access path. Neither may the setup agent.
- Secrets never enter git, logs, Slack, or agent transcripts.
- Everything on the laptop: backups protect against bad repairs and corruption, not theft or disk death. Total power/internet loss can't alert until the machine is back.

State on the laptop lives in `C:\ProgramData\openclaw-ops\` (logs, state.json, DPAPI secrets, backups, snapshots, reports) and `~/.openclaw-ops/` inside WSL.
