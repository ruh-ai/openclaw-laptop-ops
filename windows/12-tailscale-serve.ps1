<# Phase 3a — Publish the OpenClaw UI/Gateway privately: Windows Tailscale Serve -> http://127.0.0.1:GATEWAY_PORT (WSL via localhost forwarding).
   Persists across reboots (--bg). Requires MagicDNS + HTTPS certs enabled in the admin console. Idempotent. #>
param([switch]$Reset)
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Assert-Admin
$site = Import-SiteConfig
$changed = @(); $verified = @(); $open = @()
$exe = Get-TailscaleExe; if (-not $exe) { throw 'Tailscale not installed — run 10-tailscale.ps1' }
$target = $site['LOCAL_GATEWAY_URL']; $https = $site['TS_SERVE_HTTPS_PORT']
if ($Reset) { & $exe serve reset | Out-Null; $changed += 'serve reset' }
if (-not (Test-TcpPort -Port ([int]$site['GATEWAY_PORT']))) { $open += "Nothing listening on 127.0.0.1:$($site['GATEWAY_PORT']) from Windows — is the gateway running in WSL and is localhostForwarding on? Serve will be configured anyway." }
$cur = (& $exe serve status 2>&1) | Out-String
if ($cur -match [regex]::Escape($target) -and $cur -match ":$https") { $verified += 'serve already configured' }
else {
    Write-OpsLog -Component serve -Message "tailscale serve --bg --https=$https $target"
    & $exe serve --bg "--https=$https" $target
    if ($LASTEXITCODE -ne 0) { throw 'tailscale serve failed. Most common cause: HTTPS certificates not enabled for the tailnet (admin console > DNS > HTTPS Certificates).' }
    $changed += "serve --bg https:$https -> $target"
}
$cur = (& $exe serve status 2>&1) | Out-String; Write-Host $cur
$url = $site['TS_URL']; if (-not $url) { $open += 'TS_TAILNET empty in site.env — set it (10-tailscale.ps1 prints it)' }
else {
    if (Test-HttpOk -Url "$url/") { $verified += "$url/ responds" } else { $open += "$url/ did not respond from this machine (cert issuance can take ~1 min on first serve; re-run 90-verify)" }
}
$open += "[SECOND DEVICE] Open $url in a browser on another tailnet device: Control UI must load and accept the gateway token. If the UI loads but pairing fails, Phase 3b (trustedProxies/allowedOrigins) is wrong — check 21-wsl-openclaw.ps1 output."
Write-PhaseResult -Phase 3 -Pass $false -Changed $changed -Verified $verified -Open $open
