<# Phase 2b/3b — OpenClaw as a systemd user service + hardened gateway config, driven from Windows.
   Runs wsl/10-openclaw-service.sh then wsl/20-harden-config.sh as WSL_USER, then verifies from Windows localhost.
   -ProxySource: value for gateway.trustedProxies, i.e. the source IP the gateway sees for Windows-Serve-proxied
   connections (VERIFY-ON-SITE: run once without it, connect via TS_URL from a second device, read
   `openclaw logs` / journal for the rejected peer address, then re-run with -ProxySource <ip>). #>
param([string]$ProxySource = '', [switch]$SkipInstall)
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$site = Import-SiteConfig
$changed = @(); $verified = @(); $open = @()
if (-not $SkipInstall) {
    $r = Invoke-WslScript -Script 'wsl/10-openclaw-service.sh' -TimeoutSec 1800
    Write-Host $r.Output
    if ($r.ExitCode -ne 0) { throw "wsl/10-openclaw-service.sh failed (exit $($r.ExitCode))" }
    $changed += 'openclaw installed/verified; systemd user service enabled'
}
$hardenArgs = @()
if ($site['TS_URL']) { $hardenArgs += "--origin=$($site['TS_URL'])" }
if ($ProxySource) { $hardenArgs += "--trusted-proxy=$ProxySource" }
$r = Invoke-WslScript -Script 'wsl/20-harden-config.sh' -Arguments $hardenArgs -TimeoutSec 600
Write-Host $r.Output
if ($r.ExitCode -ne 0) { throw "wsl/20-harden-config.sh failed (exit $($r.ExitCode))" }
$changed += 'gateway config hardened (token auth, loopback bind, allowedOrigins' + $(if ($ProxySource) { ", trustedProxies=$ProxySource" } else { '' }) + ')'

# Verify from Windows
$port = [int]$site['GATEWAY_PORT']
if (Test-TcpPort -Port $port) { $verified += "127.0.0.1:$port reachable from Windows (localhost forwarding OK)" } else { $open += "127.0.0.1:$port NOT reachable from Windows — check .wslconfig localhostForwarding and that the gateway binds loopback" }
$h = Invoke-WslScript -Script 'wsl/healthcheck.sh' -TimeoutSec 120
Write-Host $h.Output
if ($h.ExitCode -eq 0) { $verified += 'wsl/healthcheck.sh: service active + RPC OK' } else { $open += 'wsl/healthcheck.sh failed — see output' }
if (-not $ProxySource) { $open += 'trustedProxies not set yet: do the second-device test via TS_URL, read the peer IP from `openclaw logs`, re-run: .\windows\21-wsl-openclaw.ps1 -SkipInstall -ProxySource <ip>' }
Write-PhaseResult -Phase 2 -Pass $false -Changed $changed -Verified $verified -Open $open
